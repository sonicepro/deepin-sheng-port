#!/bin/bash
# kmre-fixups: host-side fixups for the kmre Android container on sheng (SM8550).
#
# 1) CPU cap. /opt/system/bin/kylin-kmre-daemon creates the container with
#    NanoCpus=1000000000 (exactly 1 CPU) because it sizes it from a whitelist of
#    domestic CPUs (FT1500a/FT2000A/KunPeng920/Kirin990/Kirin9006c/Kirin9000c/
#    Phytium D2000/D3000/PanguM900...). SM8550 isn't in that list -> 1 core.
#    Crucially the daemon also RE-ASSERTS that 1-core quota on its own while the
#    container keeps running -- measured ~12s after an app launch -- so every app
#    cold start runs pinned to a single core until we bump it back. We therefore
#    poll the quota tightly and re-apply the instant it drops (loop at bottom).
#
# 2) Broken 32-bit daemons. cameraserver / media(mediaserver) / drm(drmserver) /
#    vendor.cas-hal-1-2 are ELF32 and the sheng kernel is AArch64-only, so init
#    fork/exec-fails them every ~5s ("Exec format error", 1800+ times). They can
#    never run; stop the retry loop (ctl.stop disables the service at runtime).
set -u

DOCKER=/opt/system/bin/docker
CONTAINER=kmre-1000-luser
NCPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 8)"
# Give Android all cores (they still share fairly with the host compositor via CFS).
# Set to $(( NCPU - 1 )) if you want to reserve a core for the desktop/compositor.
TARGET=$NCPU
WANT="$(( TARGET * 100000 )) 100000"
BROKEN_SVCS="cameraserver media drm vendor.cas-hal-1-2"

apply_cpu() {  # arg: container id (empty -> no-op); returns 1 if the quota changed
    cid="$1"
    [ -n "$cid" ] || return 0
    cg="/sys/fs/cgroup/system.slice/docker-${cid}.scope/cpu.max"
    cur="$(cat "$cg" 2>/dev/null || true)"
    [ "$cur" = "$WANT" ] && return 0
    # Primary: let docker update both its config and the cgroup.
    "$DOCKER" update --cpus="$TARGET" "$CONTAINER" >/dev/null 2>&1 || true
    # Fallback: write the cgroup directly.
    now="$(cat "$cg" 2>/dev/null || true)"
    if [ "$now" != "$WANT" ] && [ -w "$cg" ]; then
        echo "$WANT" > "$cg" 2>/dev/null || true
    fi
    logger -t kmre-fixups "cpu: $CONTAINER -> $TARGET cpus (was ${cur:-?})" 2>/dev/null || true
    return 1   # quota changed -> caller re-checks quickly
}

stop_broken_daemons() {  # arg: container pid
    pid="$1"
    [ -n "$pid" ] && [ "$pid" != 0 ] && [ -d "/proc/$pid" ] || return 0
    for s in $BROKEN_SVCS; do
        nsenter -t "$pid" -m -p /system/bin/setprop ctl.stop "$s" >/dev/null 2>&1 || true
    done
}

# The daemon re-asserts a 1-core quota on its own while the container runs, so we
# poll the quota tightly -- one tiny file read every 0.25s -- and re-apply the
# instant it drops. That shrinks the single-core window from up to 30s to ~0.25s.
# The heavier work (container-id refresh + stopping the 32-bit daemon retry
# loops) rides a ~30s beat; when the container is absent we sleep longer so we
# don't hammer the docker CLI.
HK_TICKS=120           # 120 * 0.25s = 30s housekeeping beat
tick=0
cid=""
cg=""
while :; do
    # (Re)resolve the container id only if we have none or its cgroup vanished.
    if [ -z "$cid" ] || [ ! -e "$cg" ]; then
        cid="$("$DOCKER" inspect -f '{{.Id}}' "$CONTAINER" 2>/dev/null)"
        if [ -n "$cid" ]; then
            cg="/sys/fs/cgroup/system.slice/docker-${cid}.scope/cpu.max"
        else
            cg=""
        fi
    fi
    if [ -n "$cg" ]; then
        apply_cpu "$cid" || true        # cheap (one read) when already correct
        tick=$(( tick + 1 ))
        if [ "$tick" -ge "$HK_TICKS" ]; then
            tick=0
            stop_broken_daemons "$("$DOCKER" inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null)"
        fi
        sleep 0.25
    else
        sleep 2                          # container not up; don't hammer docker
    fi
done
