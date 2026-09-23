#!/bin/bash
# =============================================================================
# sheng-openkylin-rootfs_build.sh — openKylin arm64 rootfs for Xiaomi Pad 6S Pro
# =============================================================================
# Approach A (bootstrap): unlike Deepin, openKylin PUBLISHES an arm64 apt
# archive (http://archive.build.openkylin.top/openkylin/, dists + pool,
# components "main cross pty"). So — exactly like the upstream ianchb/debian-sheng
# and code002-2/ubuntu-sheng projects — we bootstrap the base userland straight
# from the distribution's own repository (mmdebstrap, with a debootstrap
# fallback), then inject the sheng kernel .deb + firmware + MIPPS, apply the
# device quirks, and emit a fastboot-flashable sparse rootfs.
#
# (Deepin needed the other approach — unpack a prebuilt arm64 image — because its
#  community mirror carries no arm64 packages at all; see
#  sheng-deepin-rootfs_build.sh.)
#
# Self-contained: sources ./lib/rootfs-common.sh (vendored in this repo).
# Driven by .github/workflows/build-openkylin.yml (runs-on: ubuntu-24.04-arm).
#
# Usage:
#   sudo bash sheng-openkylin-rootfs_build.sh openkylin-desktop 7.1 dual ukui
#     args: <distro-variant> <kernel_version> [boot_mode: single|dual|all] [desktop_env]
#           desktop_env = 桌面元包名（默认 ukui）；传 none/- 只出无桌面的基础系统
#
# Output (one per boot mode):
#   openkylin_<ver>_<mode>_<ts>.img.gz   (Android-sparse ext4 rootfs, gzip)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rootfs-common.sh"

# --- Configuration -----------------------------------------------------------
# Empty IMAGE_SIZE => auto-size from the bootstrapped base (+ a desktop margin).
IMAGE_SIZE="${IMAGE_SIZE:-}"
UUID="${UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"   # repo default

# openKylin release. Default 3.0 "huanghe" (latest release). Other suites:
#   nile (2.0) / nile.bedrock (2.0 SP2) / yangtze (1.0)
OPENKYLIN_VERSION="${OPENKYLIN_VERSION:-3.0}"
OPENKYLIN_SUITE="${OPENKYLIN_SUITE:-huanghe}"
OPENKYLIN_MIRROR="${OPENKYLIN_MIRROR:-http://archive.build.openkylin.top/openkylin/}"
OPENKYLIN_COMPONENTS="${OPENKYLIN_COMPONENTS:-main,cross,pty}"
OPENKYLIN_KEYRING_URL="${OPENKYLIN_KEYRING_URL:-${OPENKYLIN_MIRROR}project/openkylin-archive-keyring.gpg}"
OPENKYLIN_KEYRING_PATH="${OPENKYLIN_KEYRING_PATH:-/usr/share/keyrings/openkylin-archive-keyring.gpg}"

# Desktop meta package. openKylin's desktop is UKUI; the real meta package is
# 'ukui-desktop-environment' (confirmed present in the huanghe/nile indexes).
# For the touch/tablet UI there is also 'ukui-tablet-desktop'. Installed
# BEST-EFFORT — a miss warns, it does not fail the build. Override via env.
OPENKYLIN_DESKTOP_META="${OPENKYLIN_DESKTOP_META:-ukui-desktop-environment}"

ROOT_PASS="${ROOT_PASS:-1234}"
USER_PASS="${USER_PASS:-luser}"
USER_NAME="${USER_NAME:-luser}"
SYSTEM_HOSTNAME="${SYSTEM_HOSTNAME:-sheng}"
SYSTEM_LOCALE="${SYSTEM_LOCALE:-zh_CN.UTF-8}"
SYSTEM_TIMEZONE="${SYSTEM_TIMEZONE:-Asia/Shanghai}"

# Core packages for a usable system. Installed via the *chroot's own apt* AFTER
# the minimal bootstrap (openKylin's apt resolves the pre-t64 vs t64 transition
# correctly; debootstrap's resolver does not -- see bootstrap_openkylin).
# Kept comma-separated; converted to spaces where used.
CORE_PACKAGES="ca-certificates,systemd,systemd-sysv,sudo,openssh-server,network-manager,iproute2,kmod,udev,dbus,locales,e2fsprogs,util-linux,bash"

# --- Args --------------------------------------------------------------------
validate_args 2 4 $# '<distro-variant> <kernel_version> [boot_mode] [desktop_env]'
validate_root

DISTRO=$1
KERNEL=$2
TARGET_MODE=${3:-dual}
TARGET_FLAVOUR=${4:-}       # 4th arg selects the desktop meta (see below)

# The 4th positional arg, when given, selects the desktop meta package and
# overrides OPENKYLIN_DESKTOP_META. Pass "none" (or "-") to build a headless base.
case "$TARGET_FLAVOUR" in
    '')     : ;;                                   # keep env / default (ukui)
    none|-) OPENKYLIN_DESKTOP_META="" ;;
    *)      OPENKYLIN_DESKTOP_META="$TARGET_FLAVOUR" ;;
esac

TIMESTAMP=$(generate_timestamp)

# --- Extraction/bootstrap tools (runner may not ship these; idempotent) -------
_missing=0
for _t in mmdebstrap debootstrap wget rsync xz zstd ar losetup; do
    command -v "$_t" >/dev/null 2>&1 || _missing=1
done
if [ "$_missing" -eq 1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        mmdebstrap debootstrap wget rsync xz-utils zstd binutils util-linux
fi

# --- openKylin archive keyring ----------------------------------------------
download_openkylin_keyring() {
    mkdir -p "$(dirname "$OPENKYLIN_KEYRING_PATH")"
    [ -s "$OPENKYLIN_KEYRING_PATH" ] && return 0
    echo "==> Fetching openKylin archive keyring: ${OPENKYLIN_KEYRING_URL}"
    if ! wget -nv -O "$OPENKYLIN_KEYRING_PATH" "$OPENKYLIN_KEYRING_URL"; then
        echo "ERROR: could not download the openKylin keyring; override OPENKYLIN_KEYRING_URL" >&2
        rm -f "$OPENKYLIN_KEYRING_PATH"
        return 1
    fi
}

# --- Bootstrap the openKylin base userland into <dest> -----------------------
# openKylin 3.0 "huanghe" ships zstd-compressed .deb payloads (data.tar.zst);
# 2.0 "nile" still ships xz. A host dpkg-deb that can't decode zstd makes BOTH
# the default debootstrap `dpkg-deb` extractor AND mmdebstrap fail (mmdebstrap:
# "chroot: ... dpkg: No such file or directory" after an empty extraction;
# debootstrap: "Tried to extract package, but tar failed"). So we drive
# debootstrap with the raw `ar` extractor (EXTRACTOR_OVERRIDE=ar), which shells
# out to `zstdcat`/`xzcat` -- the `zstd`/`xz-utils` CLI we install -- so the
# payload compression is handled by the CLI regardless of the host dpkg.
#
# openKylin is Ubuntu-derived and split-usr, so debootstrap's generic Ubuntu
# script ('gutsy') is symlinked in for the suite name.
bootstrap_openkylin() {
    local dest="$1"
    mkdir -p "$dest"
    local keyargs=()
    [ -s "$OPENKYLIN_KEYRING_PATH" ] && keyargs=(--keyring="$OPENKYLIN_KEYRING_PATH")

    # 1) debootstrap with the `ar` extractor (handles both xz and zstd payloads).
    if command -v debootstrap >/dev/null 2>&1; then
        local sdir="/usr/share/debootstrap/scripts"
        [ -e "$sdir/$OPENKYLIN_SUITE" ] || ln -sf gutsy "$sdir/$OPENKYLIN_SUITE"
        echo "==> Bootstrap (debootstrap extractor=ar ${OPENKYLIN_SUITE} -> ${dest})"
        if EXTRACTOR_OVERRIDE=ar debootstrap --arch=arm64 --variant=minbase \
              --components="$OPENKYLIN_COMPONENTS" \
              "${keyargs[@]}" \
              --include=apt \
              "$OPENKYLIN_SUITE" "$dest" "$OPENKYLIN_MIRROR" \
              && [ -x "$dest/usr/bin/apt-get" ]; then
            echo "    base userland ready (debootstrap)"
            return 0
        fi
        echo "WARN: debootstrap failed; tail of debootstrap.log:" >&2
        if [ -f "$dest/debootstrap/debootstrap.log" ]; then
            tail -n 30 "$dest/debootstrap/debootstrap.log" >&2 || true
        fi
        rm -rf "$dest"; mkdir -p "$dest"
    fi

    # 2) mmdebstrap fallback (native apt install; cleanest for xz-only suites).
    command -v mmdebstrap >/dev/null 2>&1 \
        || { echo "ERROR: neither a working debootstrap nor mmdebstrap is available" >&2; return 1; }
    echo "==> Bootstrap (mmdebstrap ${OPENKYLIN_SUITE} -> ${dest})"
    if mmdebstrap \
          --architectures=arm64 \
          --variant=minbase \
          --components="$OPENKYLIN_COMPONENTS" \
          "${keyargs[@]}" \
          --include=apt \
          --mode=root \
          "$OPENKYLIN_SUITE" "$dest" "$OPENKYLIN_MIRROR" \
          && [ -x "$dest/usr/bin/apt-get" ]; then
        echo "    base userland ready (mmdebstrap)"
        return 0
    fi

    echo "ERROR: bootstrap failed: no usable /usr/bin/apt-get in the target" >&2
    return 1
}

# --- openKylin / lightdm autologin (UKUI uses lightdm) -----------------------
setup_openkylin_autologin() {
    local rootdir="$1" user="$2"
    mkdir -p "$rootdir/etc/lightdm/lightdm.conf.d"
    cat > "$rootdir/etc/lightdm/lightdm.conf.d/00-sheng-autologin.conf" <<EOF
[Seat:*]
autologin-user=${user}
autologin-user-timeout=0
EOF
}

# --- Bootstrap once up front (so we can size the image to fit) ---------------
echo "==> Bootstrapping openKylin ${OPENKYLIN_VERSION} (${OPENKYLIN_SUITE}) arm64..."
STAGE="$(mktemp -d)"
download_openkylin_keyring
bootstrap_openkylin "$STAGE"
base_mb=$(du -sm "$STAGE" | cut -f1)
echo "==> Bootstrapped base: ${base_mb} MiB"

if [ -z "$IMAGE_SIZE" ]; then
    # +3 GiB headroom: a desktop install, the kernel/firmware payloads and ext4
    # metadata all land after this, and du undercounts hardlinked content.
    IMAGE_SIZE="$((base_mb + 3072))M"
fi
echo "==> Target image size: ${IMAGE_SIZE}"

# --- Build loop over boot modes ---------------------------------------------
mapfile -t BOOTMODES < <(parse_boot_modes "$TARGET_MODE") || exit 1
MODES_LEFT=${#BOOTMODES[@]}

for MODE in "${BOOTMODES[@]}"; do
    echo ""
    echo "======================================================"
    echo "构建 openKylin ${OPENKYLIN_VERSION} | 模式: $MODE"
    echo "======================================================"

    preflight_checks 10240

    ROOTFS_IMG="openkylin_${OPENKYLIN_VERSION}_${MODE}_${TIMESTAMP}.img"

    # 1. Create the ext4 image and mount it at $ROOTDIR
    create_image "$IMAGE_SIZE" "$ROOTFS_IMG" "$UUID"
    setup_chroot_mounts "$ROOTDIR"
    trap_teardown "$ROOTDIR"

    # 2. Flatten the bootstrapped base into the image (preserve perms/xattrs).
    echo "==> Copying base into ${ROOTFS_IMG}..."
    rsync -aHAX --numeric-ids "$STAGE/" "$ROOTDIR/"

    # Free the staging tree before the (space-hungry) sparse pack, unless a
    # later boot mode still needs it.
    MODES_LEFT=$((MODES_LEFT - 1))
    [ "$MODES_LEFT" -eq 0 ] && rm -rf "$STAGE"

    # 3. DNS inside chroot. Prefer the RUNNER's own resolvers: GitHub runners
    #    resolve through an internal nameserver and commonly can't reach
    #    8.8.8.8/1.1.1.1 directly -- a chroot apt seeded only with public DNS then
    #    fails name resolution and installs nothing (silently), which is exactly
    #    why the "grow the base via chroot apt" step produced a ~283MB image with
    #    no desktop. Keep public DNS as a fallback.
    {
        grep -E '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null || true
        echo 'nameserver 8.8.8.8'
        echo 'nameserver 1.1.1.1'
    } > "$ROOTDIR/etc/resolv.conf"

    # 3b. apt sources. mmdebstrap/debootstrap wrote a minimal list; make it
    # explicit + add the -updates/-security pockets (openKylin uses Ubuntu-style
    # pocket names). Components are exactly "main cross pty".
    cat > "$ROOTDIR/etc/apt/sources.list" <<EOF
deb ${OPENKYLIN_MIRROR} ${OPENKYLIN_SUITE} main cross pty
deb ${OPENKYLIN_MIRROR} ${OPENKYLIN_SUITE}-updates main cross pty
deb ${OPENKYLIN_MIRROR} ${OPENKYLIN_SUITE}-security main cross pty
EOF
    # 3b. Make the target's apt trust openKylin. debootstrap verified the archive
    #     with our host keyring but does not install that keyring into the target,
    #     so the chroot's apt would fail NO_PUBKEY. Drop the keyring where apt
    #     reads it.
    mkdir -p "$ROOTDIR/etc/apt/trusted.gpg.d"
    install -m644 "$OPENKYLIN_KEYRING_PATH" \
        "$ROOTDIR/etc/apt/trusted.gpg.d/openkylin-archive-keyring.gpg" 2>/dev/null || true
    echo "==> apt-get update (populate package lists)..."
    _aptupd="$(mktemp)"
    if ! chroot "$ROOTDIR" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update" >"$_aptupd" 2>&1; then
        echo "WARN: apt-get update reported errors; tail:" >&2
        tail -n 15 "$_aptupd" >&2 || true
    fi
    rm -f "$_aptupd"

    # 3c. Grow the minimal base with the chroot's own apt. openKylin's repo
    #     carries BOTH the pre-t64 and t64 variants of several core libs
    #     (libssl3 + libssl3t64, libgnutls30 + libgnutls30t64, ...); debootstrap's
    #     resolver has no Breaks/Replaces handling so it installs both and they
    #     fail to configure. apt does handle the transition, so the base is
    #     bootstrapped bare and grown here. policy-rc.d keeps services from
    #     being started inside the chroot during postinst.
    printf '#!/bin/sh\nexit 101\n' > "$ROOTDIR/usr/sbin/policy-rc.d"
    chmod 0755 "$ROOTDIR/usr/sbin/policy-rc.d"
    echo "==> Installing core packages via chroot apt..."
    if chroot "$ROOTDIR" bash -c \
         "export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends ${CORE_PACKAGES//,/ }"; then
        echo "    core packages installed"
    else
        echo "WARN: some core packages failed to install; continuing" >&2
    fi
    rm -f "$ROOTDIR/usr/sbin/policy-rc.d"

    # 4. Desktop meta (best-effort). A wrong/renamed meta must not sink the
    #    build: the base stays bootable and reachable over SSH.
    if [ -n "$OPENKYLIN_DESKTOP_META" ]; then
        echo "==> Installing desktop meta: ${OPENKYLIN_DESKTOP_META} (best-effort)..."
        if chroot "$ROOTDIR" bash -c \
             "export DEBIAN_FRONTEND=noninteractive; apt-get install -y ${OPENKYLIN_DESKTOP_META}"; then
            echo "    desktop installed: ${OPENKYLIN_DESKTOP_META}"
        else
            echo "WARN: desktop meta '${OPENKYLIN_DESKTOP_META}' did not install; base image only" >&2
        fi
    fi

    # Diagnostic + hard-fail. If the chroot apt install didn't land, the rootfs
    # stays tiny (~283MB) and the image is useless. Abort rather than silently
    # ship a broken image, so the failing step's apt output is what gets looked at.
    _rootmb=$(du -sm "$ROOTDIR" | cut -f1)
    _npkg=$(chroot "$ROOTDIR" bash -c 'dpkg -l 2>/dev/null | grep -c "^ii"' || echo 0)
    echo "==> Rootfs after core+desktop: ${_rootmb} MiB, ${_npkg} packages"
    if [ -n "$OPENKYLIN_DESKTOP_META" ] && [ "${_rootmb:-0}" -lt 800 ]; then
        echo "ERROR: rootfs is only ${_rootmb} MiB after installing core+desktop -- the chroot apt install did not land (see the apt output above). Aborting." >&2
        exit 1
    fi

    # 4b. Optional device helper packages (best-effort; names vary by suite).
    chroot "$ROOTDIR" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y qrtr" >/dev/null 2>&1 || true

    # 5. Inject the sheng kernel .deb (placed in cwd by the workflow)
    echo "==> Injecting sheng kernel .deb..."
    inject_deb_kernel "$ROOTDIR" "./*.deb"

    # 5b. Firmware. Same two problems as on Deepin: the shipped
    #     firmware-xiaomi-sheng .deb lands blobs under /usr/lib/<driver>/ (the
    #     kernel only searches /lib/firmware/), and it omits the Adreno GPU
    #     firmware (qcom/a740_sqe.fw + qcom/gmu_gen70200.bin) that the display
    #     needs. Copy the deb's blobs into /lib/firmware/ then overlay the full
    #     source-repo firmware set.
    echo "==> Installing sheng firmware into /lib/firmware/..."
    mkdir -p "$ROOTDIR/lib/firmware"
    for _d in ath12k cirrus novatek qca qcom nanosic; do
        [ -d "$ROOTDIR/usr/lib/$_d" ] && cp -a "$ROOTDIR/usr/lib/$_d" "$ROOTDIR/lib/firmware/"
    done
    fwdir="$(mktemp -d)"
    wget -nv -O "$fwdir/fw.tar.gz" \
        "${FIRMWARE_URL:-https://github.com/sonicepro/deepin-sheng-port/releases/download/kernel-bundle-7.1/sheng-firmware-master.tar.gz}"
    tar -xzf "$fwdir/fw.tar.gz" -C "$fwdir"
    fwsrc="$(find "$fwdir" -maxdepth 1 -mindepth 1 -type d -name 'sheng-firmware-*' | head -1)"
    [ -n "$fwsrc" ] && cp -a "$fwsrc"/. "$ROOTDIR/lib/firmware/"
    rm -rf "$fwdir"
    echo "    /lib/firmware/qcom:"; ls "$ROOTDIR/lib/firmware/qcom" 2>/dev/null || true

    # 5c. Xiaomi MIPPS 120W charger authentication (kernel already exposes the
    #     pmic-glink xiaomi sysfs node; this daemon + udev rule do the handshake).
    echo "==> Installing Xiaomi MIPPS auth (120W charging)..."
    _mipps="$(mktemp -d)/mipps.deb"
    if wget -nv -O "$_mipps" "${MIPPS_DEB_URL:-https://github.com/sonicepro/deepin-sheng-port/releases/download/kernel-bundle-7.1/xiaomi-mipps-auth.deb}"; then
        dpkg-deb --fsys-tarfile "$_mipps" | tar -x --keep-directory-symlink -C "$ROOTDIR/"
        echo "    installed /usr/libexec/xiaomi-mipps-auth (+ service + udev rule)"
    else
        echo "    WARN: MIPPS deb download failed; 120W charging auth skipped" >&2
    fi
    rm -rf "$(dirname "$_mipps")"

    # 6. Device quirks (shared helpers from lib/rootfs-common.sh).
    # NB: no setup_getty_ttyMSM0 — the kernel disables the geni serial
    # (cmdline qcom_geni_serial.con_enabled=0), so /dev/ttyMSM0 does not exist.
    setup_qrtr_service "$ROOTDIR"
    if [ ! -e "$ROOTDIR/usr/bin/qrtr-ns" ]; then
        mkdir -p "$ROOTDIR/etc/systemd/system/qrtr-ns.service.d"
        printf '[Unit]\nConditionPathExists=/usr/bin/qrtr-ns\n' \
            > "$ROOTDIR/etc/systemd/system/qrtr-ns.service.d/10-skip-if-absent.conf"
    fi
    configure_touchscreen "$ROOTDIR"
    fix_wifi_firmware "$ROOTDIR"

    # Bluetooth HID (mice/keyboards) goes through uhid (BLE) / hidp (BR-EDR);
    # both are modules nothing auto-loads, so a paired mouse can't connect until
    # they're loaded at boot.
    printf 'uhid\nhidp\n' > "$ROOTDIR/etc/modules-load.d/sheng-bluetooth-hid.conf"

    # Remove any NetworkManager connections the base might ship, so first boot
    # never tries a foreign (wrong) profile before the user's own.
    rm -f "$ROOTDIR"/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true

    # 6b. Device system files (generic-only overlay; NOT the Deepin/DDE
    #     system_files/, which is full of DDE-specific units).
    if [ -d "$SCRIPT_DIR/system_files_openkylin" ]; then
        cp -a "$SCRIPT_DIR/system_files_openkylin/." "$ROOTDIR/"
        chmod 0755 "$ROOTDIR"/usr/local/sbin/*.sh 2>/dev/null || true
    fi

    # 7. Users + hostname + locale + timezone.
    setup_users "$ROOTDIR" "$ROOT_PASS" "$USER_NAME" "$USER_PASS" \
        "sudo,audio,video,render,input,plugdev,netdev"
    echo "${SYSTEM_HOSTNAME}" > "$ROOTDIR/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$SYSTEM_HOSTNAME" > "$ROOTDIR/etc/hosts"
    printf 'LANG=%s\n' "$SYSTEM_LOCALE" > "$ROOTDIR/etc/default/locale"
    printf '%s\n'        "$SYSTEM_LOCALE" > "$ROOTDIR/etc/locale.conf" 2>/dev/null || true
    # Generate the locales (locales is in CORE_PACKAGES). Duplicate lines in
    # locale.gen are harmless, so we just append both entries unconditionally.
    {
        printf '%s UTF-8\n' "$SYSTEM_LOCALE"
        printf 'en_US.UTF-8 UTF-8\n'
    } >> "$ROOTDIR/etc/locale.gen"
    chroot "$ROOTDIR" locale-gen >/dev/null 2>&1 || true
    chroot "$ROOTDIR" ln -sf "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" /etc/localtime 2>/dev/null || true
    printf '%s\n' "$SYSTEM_TIMEZONE" > "$ROOTDIR/etc/timezone"

    # 8. Autologin + services + default graphical target (best effort).
    setup_openkylin_autologin "$ROOTDIR" "$USER_NAME"
    chroot "$ROOTDIR" systemctl enable NetworkManager 2>/dev/null || true
    chroot "$ROOTDIR" systemctl enable ssh  2>/dev/null || chroot "$ROOTDIR" systemctl enable sshd 2>/dev/null || true
    chroot "$ROOTDIR" systemctl set-default graphical.target 2>/dev/null || true

    # 9. fstab (bound by PARTLABEL, matches the boot.img cmdline)
    generate_fstab "$ROOTDIR" "$MODE"

    # 10. Unmount, stamp UUID, convert to Android sparse (.img) + gzip.
    # Emit the sparse image DIRECTLY (no 7z wrapper): GitHub artifacts download
    # as a .zip, so a bare .img means a single extraction; in the release the
    # split parts `cat` straight into the flashable image.
    teardown_mounts "$ROOTDIR"
    apply_fs_uuid "$UUID" "$ROOTFS_IMG"
    echo "==> Converting ${ROOTFS_IMG} to Android sparse + gzip..."
    img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
    rm -f "$ROOTFS_IMG"
    gzip -6 "sparse_${ROOTFS_IMG}"
    mv "sparse_${ROOTFS_IMG}.gz" "${ROOTFS_IMG}.gz"
    echo "==> Image: ${ROOTFS_IMG}.gz ($(du -h "${ROOTFS_IMG}.gz" | cut -f1))  (gzip -d -> ${ROOTFS_IMG})"

    echo "[MODE=$MODE] 完成！"
done

echo "[OK] openKylin arm64 rootfs build complete!"
