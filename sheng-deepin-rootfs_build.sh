#!/bin/bash
# =============================================================================
# sheng-deepin-rootfs_build.sh — Deepin arm64 rootfs for Xiaomi Pad 6S Pro
# =============================================================================
# Approach B (no debootstrap): Deepin ships NO arm64 package repo on the
# community mirror (dists/apricot/Release lists only amd64 + i386). Its arm64
# userland exists only as prebuilt deepin-ports images. So instead of
# debootstrapping, we take a prebuilt Deepin arm64 userland, flatten it into a
# plain ext4 image, inject the sheng kernel .deb, apply the device quirks, and
# emit a fastboot-flashable sparse rootfs.
#
# Self-contained: sources ./lib/rootfs-common.sh (vendored in this repo).
# Driven by .github/workflows/build-deepin.yml (runs-on: ubuntu-24.04-arm).
#
# Supported sources (auto-detected by extension), override with DEEPIN_SRC_URL:
#   *.iso          official arm64 ISO   -> unsquashfs the live filesystem
#   *.tar.xz/.zst  deepin-ports flat     -> tar -x
#   *.img.xz/.gz   board image           -> decompress, mount ext4 part, rsync
#   *.zip          FlatBuild             -> unzip
#
# Usage (same arg contract as sheng-rootfs_build.sh):
#   sudo bash sheng-deepin-rootfs_build.sh deepin-desktop 7.1 single dde
#     args: <distro-variant> <kernel_version> [boot_mode: single|dual|all] [flavour]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rootfs-common.sh"

# --- Configuration -----------------------------------------------------------
# Empty IMAGE_SIZE => auto-size from the extracted rootfs (+1 GiB headroom).
IMAGE_SIZE="${IMAGE_SIZE:-}"
UUID="${UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"   # repo default
DEEPIN_VERSION="${DEEPIN_VERSION:-25.2.0}"
# Default source: the OFFICIAL generic arm64 Deepin userland (community ISO).
# Its chip list is Phytium/Kunpeng (ARM server SoCs), but the userland is plain
# ARMv8-A and also runs on SM8550. Override with DEEPIN_SRC_URL.
DEEPIN_SRC_URL="${DEEPIN_SRC_URL:-https://cdimage.deepin.com/releases/${DEEPIN_VERSION}/arm64/deepin-desktop-community-${DEEPIN_VERSION}-arm64.iso}"

ROOT_PASS="${ROOT_PASS:-1234}"
USER_PASS="${USER_PASS:-luser}"
USER_NAME="${USER_NAME:-luser}"

# --- Args --------------------------------------------------------------------
validate_args 2 4 $# '<distro-variant> <kernel_version> [boot_mode] [desktop_env]'
validate_root

DISTRO=$1
KERNEL=$2
TARGET_MODE=${3:-single}
TARGET_FLAVOUR=${4:-dde}   # Deepin has a single DE (DDE); accepted and ignored

TIMESTAMP=$(generate_timestamp)

# --- Extraction tools (runner image may not ship these; idempotent) ----------
_missing=0
for _t in unsquashfs zstd unzip rsync xz losetup; do
    command -v "$_t" >/dev/null 2>&1 || _missing=1
done
if [ "$_missing" -eq 1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        squashfs-tools zstd unzip rsync xz-utils util-linux
fi

# --- Download the Deepin source once ----------------------------------------
DLDIR="$(mktemp -d)"
# Keep the URL's basename so the extension survives the download — fetch_rootfs
# dispatches on extension (.iso / .tar.xz / .img.xz / .zip).
src_name="$(basename "${DEEPIN_SRC_URL%%\?*}")"
{ [ -n "${src_name}" ] && [ "${src_name}" != "/" ]; } || src_name="deepin-src"
src_file="${DLDIR}/${src_name}"
echo "==> Fetching Deepin arm64 source: ${DEEPIN_SRC_URL}"
wget -nv -O "${src_file}" "${DEEPIN_SRC_URL}"
echo "==> Source size: $(du -h "${src_file}" | cut -f1)"

# fetch_rootfs <archive> <dest_dir>  — materialize the root filesystem tree
fetch_rootfs() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    case "$src" in
        *.iso)
            local mnt; mnt="$(mktemp -d)"
            mount -o loop,ro "$src" "$mnt"
            # Deepin's live root is the UNION of several squashfs listed in
            # /LIVE/filesystem.module (e.g. filesystem.squashfs +
            # filesystem-extra.squashfs). Extract ALL of them, in module order —
            # extracting only filesystem.squashfs yields a root missing ~8 GiB
            # (the "extra" overlay: wallpapers, apps, ...).
            local modf; modf="$(find "$mnt" -maxdepth 6 \( -iname 'filesystem.module' -o -iname 'filesystem-module' \) 2>/dev/null | head -1)"
            local sqs=() f n
            if [ -n "$modf" ] && [ -s "$modf" ]; then
                while IFS= read -r n; do
                    n="$(printf '%s' "$n" | tr -d '\r')"
                    [ -n "$n" ] || continue
                    f="$(dirname "$modf")/$n"
                    [ -f "$f" ] && sqs+=("$f")
                done < "$modf"
            fi
            if [ "${#sqs[@]}" -eq 0 ]; then
                while IFS= read -r f; do sqs+=("$f"); done < <(find "$mnt" -maxdepth 6 -iname 'filesystem*.squashfs' | sort)
            fi
            if [ "${#sqs[@]}" -eq 0 ]; then
                echo "ERROR: no filesystem.squashfs found inside ISO" >&2
                umount "$mnt"; rmdir "$mnt"; return 1
            fi
            local sq
            for sq in "${sqs[@]}"; do
                echo "    squashfs: ${sq#"$mnt"/}"
                unsquashfs -f -d "$dest" "$sq"
            done
            # Keep the live package manifest so we can rebuild the dpkg database.
            local pl; pl="$(find "$mnt" -maxdepth 6 -iname 'filesystem.packages' | head -1)"
            [ -n "$pl" ] && cp "$pl" "$dest/.live-packages"
            umount "$mnt"; rmdir "$mnt"
            ;;
        *.tar.xz|*.tar.gz|*.tar.zst|*.tgz)
            tar -xaf "$src" -C "$dest" --numeric-owner
            ;;
        *.img.xz|*.img.gz)
            local tmpd; tmpd="$(mktemp -d)"
            local img="${tmpd}/root.img"
            case "$src" in
                *.img.xz) xz -dc "$src" > "$img" ;;
                *.img.gz) gzip -dc "$src" > "$img" ;;
            esac
            local loop; loop="$(losetup -fP --show "$img")"
            sleep 1
            # Pick the LARGEST ext4 partition (that's the root filesystem).
            local part="" best=0 sz=0
            for p in "${loop}"p*; do
                [ -b "$p" ] || continue
                if [ "$(blkid -o value -s TYPE "$p" 2>/dev/null || true)" = "ext4" ]; then
                    sz="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"
                    if [ "$sz" -gt "$best" ]; then best="$sz"; part="$p"; fi
                fi
            done
            if [ -z "$part" ]; then
                echo "ERROR: no ext4 partition in image" >&2
                losetup -d "$loop"; return 1
            fi
            echo "    root partition: ${part} ($((best/1024/1024)) MiB)"
            mkdir -p "${tmpd}/mnt"
            mount -o ro "$part" "${tmpd}/mnt"
            rsync -aHAX --numeric-ids "${tmpd}/mnt/" "$dest/"
            umount "${tmpd}/mnt"
            losetup -d "$loop"
            rm -rf "$tmpd"
            ;;
        *.zip)
            unzip -q "$src" -d "$dest"
            local nested_img; nested_img="$(find "$dest" -maxdepth 2 -name '*.img' | head -1)"
            if [ -n "$nested_img" ] && [ "$(find "$dest" -maxdepth 1 -mindepth 1 | wc -l)" -le 2 ]; then
                local redo; redo="$(mktemp -d)"
                fetch_rootfs "$nested_img" "$redo"
                rm -rf "$dest"; mv "$redo" "$dest"
            fi
            ;;
        *)
            # Unknown/absent extension -> sniff the magic and retry once via a
            # symlink that carries the right extension.
            local ft; ft="$(file -b "$src" 2>/dev/null || echo '')"
            local ext=""
            case "$ft" in
                *ISO\ 9660*) ext="iso" ;;
                *XZ*)        ext="tar.xz" ;;
                *gzip*)      ext="tar.gz" ;;
                *Zip*)       ext="zip" ;;
            esac
            if [ -n "$ext" ]; then
                local link="${src}.sniff.${ext}"
                ln -sf "$(readlink -f "$src")" "$link"
                echo "    (sniffed type: ${ext})"
                fetch_rootfs "$link" "$dest"
                rm -f "$link"
            else
                echo "ERROR: unsupported archive type: ${src} (file says: ${ft})" >&2
                return 1
            fi
            ;;
    esac
}

# --- Best-effort Deepin (lightdm) autologin ---------------------------------
setup_deepin_autologin() {
    local rootdir="$1" user="$2"
    mkdir -p "$rootdir/etc/lightdm/lightdm.conf.d"
    cat > "$rootdir/etc/lightdm/lightdm.conf.d/00-sheng-autologin.conf" <<EOF
[Seat:*]
autologin-user=${user}
autologin-user-timeout=0
EOF
}

# --- Rebuild the dpkg database when the source shipped none -----------------
# Deepin's live ISO has an empty/absent /var/lib/dpkg, which makes dpkg/apt
# unusable (every chroot apt step below would then no-op). Reconstruct a minimal
# database from the live package manifest (saved as .live-packages by
# fetch_rootfs) and mask the live-boot/config machinery.
rebuild_dpkg_db() {
    local root="$1"
    [ -s "$root/var/lib/dpkg/status" ] && return 0
    [ -f "$root/.live-packages" ] || return 0

    echo "==> Rebuilding dpkg database from the live package manifest..."
    mkdir -p "$root/var/lib/dpkg/info" "$root/var/lib/dpkg/updates" \
             "$root/var/lib/dpkg/triggers" "$root/var/lib/dpkg/alternatives" \
             "$root/var/lib/dpkg/parts" "$root/var/lib/apt/lists/partial" \
             "$root/var/cache/apt/archives/partial"
    : > "$root/var/lib/dpkg/status"
    local name ver arch
    while IFS=$'\t' read -r name ver; do
        [ -n "$name" ] || continue
        arch="arm64"
        case "$name" in *:*) arch="${name##*:}"; name="${name%%:*}";; esac
        printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nSection: unknown\nInstalled-Size: 0\nMaintainer: unknown\nArchitecture: %s\nVersion: %s\nDescription: (from live manifest)\n\n' \
            "$name" "$arch" "$ver" >> "$root/var/lib/dpkg/status"
    done < "$root/.live-packages"
    rm -f "$root/.live-packages"
    echo "    dpkg status: $(grep -c '^Package:' "$root/var/lib/dpkg/status" 2>/dev/null || echo 0) packages"

    # Mask the live-boot/live-config machinery so it doesn't run on a disk root.
    local u
    for u in live-config.service live-config-systemd.service live-boot.service live-tools.service; do
        if [ -e "$root/lib/systemd/system/$u" ] || [ -e "$root/usr/lib/systemd/system/$u" ] || [ -e "$root/etc/systemd/system/$u" ]; then
            mkdir -p "$root/etc/systemd/system"
            ln -sf /dev/null "$root/etc/systemd/system/$u"
        fi
    done
    rm -rf "$root/lib/live" "$root/usr/lib/live"
}

# --- Extract once up front (so we can size the image to fit) -----------------
echo "==> Extracting Deepin userland..."
STAGE="$(mktemp -d)"
fetch_rootfs "$src_file" "$STAGE"
rebuild_dpkg_db "$STAGE"
rm -rf "$DLDIR"          # reclaim the downloaded archive
extracted_mb=$(du -sm "$STAGE" | cut -f1)
echo "==> Extracted rootfs: ${extracted_mb} MiB"

if [ -z "$IMAGE_SIZE" ]; then
    # Generous headroom: du undercounts hardlinked/sparse content and ext4 adds
    # metadata, so +2 GiB keeps rsync from hitting ENOSPC.
    IMAGE_SIZE="$((extracted_mb + 2048))M"
fi
echo "==> Target image size: ${IMAGE_SIZE}"

# --- Build loop over boot modes ---------------------------------------------
mapfile -t BOOTMODES < <(parse_boot_modes "$TARGET_MODE") || exit 1
MODES_LEFT=${#BOOTMODES[@]}

for MODE in "${BOOTMODES[@]}"; do
    echo ""
    echo "======================================================"
    echo "构建 Deepin ${DEEPIN_VERSION} | 模式: $MODE"
    echo "======================================================"

    preflight_checks 10240

    ROOTFS_IMG="deepin_${DEEPIN_VERSION}_${MODE}_${TIMESTAMP}.img"

    # 1. Create the ext4 image and mount it at $ROOTDIR
    create_image "$IMAGE_SIZE" "$ROOTFS_IMG" "$UUID"
    setup_chroot_mounts "$ROOTDIR"
    trap_teardown "$ROOTDIR"

    # 2. Flatten the staged userland into the image (preserve perms/xattrs).
    # No --info=progress2: it emits one line per update and blows up the CI log.
    echo "==> Copying userland into ${ROOTFS_IMG}..."
    rsync -aHAX --numeric-ids "$STAGE/" "$ROOTDIR/"

    # 2b. The Deepin ISO ships several top-level dirs (/, /etc, /usr, ...) owned
    # by uid 1001 instead of root. systemd-tmpfiles then refuses to run ("unsafe
    # path transition"), so /run/linglong & co. are never created and *all*
    # linglong apps fail to start (QQ, bilibili, ...). Normalize to root.
    echo "==> Fixing ownership (uid 1001 -> root, outside /home)..."
    chown 0:0 "$ROOTDIR"
    find "$ROOTDIR" -xdev -uid 1001 ! -path "$ROOTDIR/home/*" -exec chown 0:0 {} + 2>/dev/null || true

    # Free the staging tree before the (space-hungry) sparse pack, unless a
    # later boot mode still needs it.
    MODES_LEFT=$((MODES_LEFT - 1))
    [ "$MODES_LEFT" -eq 0 ] && rm -rf "$STAGE"

    # 3. DNS inside chroot
    setup_dns "$ROOTDIR" 223.5.5.5 1.1.1.1 8.8.8.8

    # 3b. Ensure a usable apt repo + refresh the lists. The Deepin live root
    # ships NO /var/lib/apt/lists (and its sources may be live-specific), so the
    # `apt-get install` steps below would otherwise fail with "no such package".
    cat > "$ROOTDIR/etc/apt/sources.list" <<'EOF'
deb https://community-packages.deepin.com/beige/ crimson main commercial community
EOF
    echo "==> apt-get update (populate package lists)..."
    chroot "$ROOTDIR" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update" >/dev/null 2>&1 || true

    # 4. Inject the sheng kernel .deb (placed in cwd by the workflow)
    echo "==> Injecting sheng kernel .deb..."
    inject_deb_kernel "$ROOTDIR" "./*.deb"

    # 4b. Firmware. Two problems with what's available:
    #   * the shipped firmware-xiaomi-sheng .deb lands blobs under
    #     /usr/lib/<driver>/, but the kernel only searches /lib/firmware/;
    #   * that .deb is INCOMPLETE — it omits the Adreno GPU firmware
    #     (qcom/a740_sqe.fw + qcom/gmu_gen70200.bin), which is exactly what
    #     makes the display/GPU fail to come up.
    # So: (1) copy the deb's blobs to /lib/firmware/, then (2) overlay the full
    # source-repo set (ath12k / qcom / cirrus / novatek / qca / nanosic).
    echo "==> Installing sheng firmware into /lib/firmware/..."
    mkdir -p "$ROOTDIR/lib/firmware"
    for _d in ath12k cirrus novatek qca qcom nanosic; do
        [ -d "$ROOTDIR/usr/lib/$_d" ] && cp -a "$ROOTDIR/usr/lib/$_d" "$ROOTDIR/lib/firmware/"
    done
    fwdir="$(mktemp -d)"
    wget -nv -O "$fwdir/fw.tar.gz" \
        "${FIRMWARE_URL:-https://codeload.github.com/alghiffaryfa19/sheng-firmware/tar.gz/refs/heads/master}"
    tar -xzf "$fwdir/fw.tar.gz" -C "$fwdir"
    fwsrc="$(find "$fwdir" -maxdepth 1 -mindepth 1 -type d -name 'sheng-firmware-*' | head -1)"
    [ -n "$fwsrc" ] && cp -a "$fwsrc"/. "$ROOTDIR/lib/firmware/"
    rm -rf "$fwdir"
    echo "    /lib/firmware/qcom:"; ls "$ROOTDIR/lib/firmware/qcom" 2>/dev/null || true

    # 4c. Xiaomi MIPPS 120W charger authentication. The kernel already exposes
    # the pmic-glink xiaomi sysfs node (request_vdm_cmd); this daemon + its udev
    # rule perform the handshake so a Xiaomi 120W charger negotiates full power
    # (otherwise it stays at the standard PPS/PD rate).
    echo "==> Installing Xiaomi MIPPS auth (120W charging)..."
    _mipps="$(mktemp -d)/mipps.deb"
    if wget -nv -O "$_mipps" "${MIPPS_DEB_URL:-https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux/releases/download/mipps/xiaomi-mipps-auth_0.11_arm64.deb}"; then
        dpkg-deb --fsys-tarfile "$_mipps" | tar -x --keep-directory-symlink -C "$ROOTDIR/"
        echo "    installed /usr/libexec/xiaomi-mipps-auth (+ service + udev rule)"
    else
        echo "    WARN: MIPPS deb download failed; 120W charging auth skipped" >&2
    fi
    rm -rf "$(dirname "$_mipps")"

    # 5. Device quirks (shared with the other distro scripts)
    # NOTE: no setup_getty_ttyMSM0 here — the kernel disables the geni serial
    # (cmdline qcom_geni_serial.con_enabled=0), so /dev/ttyMSM0 does not exist
    # and a getty on it just shows up as a failed unit.
    # qrtr-ns: the unit the shared lib creates runs /usr/bin/qrtr-ns, which a
    # stock Deepin rootfs lacks -> the unit fails at boot. Install the package
    # (Debian: 'qrtr') if available, and add a ConditionPathExists safety net so
    # the unit is skipped (not "failed") when the binary is still absent.
    chroot "$ROOTDIR" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y qrtr" >/dev/null 2>&1 || true
    setup_qrtr_service "$ROOTDIR"
    if [ ! -e "$ROOTDIR/usr/bin/qrtr-ns" ]; then
        mkdir -p "$ROOTDIR/etc/systemd/system/qrtr-ns.service.d"
        printf '[Unit]\nConditionPathExists=/usr/bin/qrtr-ns\n' \
            > "$ROOTDIR/etc/systemd/system/qrtr-ns.service.d/10-skip-if-absent.conf"
    fi
    configure_touchscreen "$ROOTDIR"
    fix_wifi_firmware "$ROOTDIR"

    # The Deepin ISO ships the *builder's* NetworkManager connections (and their
    # WiFi PSKs!) under /etc/NetworkManager/system-connections. Remove them:
    # shipping someone else's credentials is a leak, and on first boot NM tries
    # the (wrong) factory profile first, fails, and prompts the user — who then
    # piles up duplicate profiles for the same SSID (-> keeps re-asking).
    rm -f "$ROOTDIR"/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true

    # 5c. Device system files + device services.
    if [ -d "$SCRIPT_DIR/system_files" ]; then
        cp -a "$SCRIPT_DIR/system_files/." "$ROOTDIR/"
        # git may not preserve the exec bit -> make the helper scripts runnable
        chmod 0755 "$ROOTDIR"/usr/local/sbin/*.sh 2>/dev/null || true
        # compile the dconf system defaults (on-screen keyboard config, etc.)
        chroot "$ROOTDIR" dconf update 2>/dev/null || true
    fi
    # WirePlumber on Deepin defaults to ACP instead of UCM, so this card exposes
    # no UCM profile (only "off"/"pro-audio") -> PipeWire falls back to a Dummy
    # output. Flip it to the UCM path so the real ALSA sinks appear.
    _wp="$ROOTDIR/usr/share/wireplumber/scripts/monitors/alsa.lua"
    if [ -f "$_wp" ]; then
        sed -i '/api\.alsa\.use-acp/ s/= true/= false/' "$_wp"
    fi
    chroot "$ROOTDIR" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y openssh-server" >/dev/null 2>&1 || true
    # Mask units that can't work here (would otherwise show as [FAILED]):
    #  * deepin-face              — no face-auth hardware on sheng
    #  * deepin-immutable-cleanup — the ISO root is an ostree/immutable
    #                               deployment; ours is a plain ext4, so it fails
    mkdir -p "$ROOTDIR/etc/systemd/system"
    for _u in deepin-face.service deepin-immutable-cleanup.service deepin-immutable-cleanup.timer; do
        ln -sf /dev/null "$ROOTDIR/etc/systemd/system/$_u"
    done
    # This is a plain ext4 root, not a Deepin "immutable" (ostree) deployment, but
    # the ISO ships /etc/deepin-immutable-ctl which makes lastore-daemon treat the
    # system as immutable and run ostree update steps that fail (no
    # /sysroot/ostree/repo) -> the DDE updater can't download. Remove it so
    # lastore uses the normal apt path.
    rm -rf "$ROOTDIR/etc/deepin-immutable-ctl"
    # PipeWire-Pulse reads /etc/pulse/default.pa; its `module-always-sink` spawns
    # a fallback null sink when the card isn't ready yet, which then sticks as
    # the default output -> no sound. Drop it so the real card is the default.
    _pa="$ROOTDIR/etc/pulse/default.pa"
    if [ -f "$_pa" ]; then
        sed -i 's|^[[:space:]]*load-module module-always-sink|#load-module module-always-sink|' "$_pa"
    fi
    # The login greeter otherwise defaults to 100% (its DConfig has no scale key)
    # -> tiny login screen on a scaled panel. system_files ships a patched
    # greeters.d/lightdm-deepin-greeter that reads the user's UI scale from
    # ~/.config/deepin/qt-theme.ini (see the chmod 711 on the home dir below).
    _qt="$ROOTDIR/etc/lightdm/deepin/qt-theme.ini"
    if [ -f "$_qt" ]; then
        sed -i 's/^ScreenScaleFactors=.*/ScreenScaleFactors=2.50/; s/^ScaleLogicalDpi=.*/ScaleLogicalDpi=240,240/' "$_qt"
    fi
    # Disable system event sounds by default: the login/logout chime is played by
    # sound-theme-player directly via ALSA, ignoring the user's PipeWire volume,
    # so it's jarringly loud. Flip the DConfig default for new users.
    _xs="$ROOTDIR/usr/share/dsg/configs/org.deepin.dde.daemon/org.deepin.XSettings.json"
    if [ -f "$_xs" ]; then
        python3 - "$_xs" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
c = d.get("contents", {})
if "enable-event-sounds" in c:
    c["enable-event-sounds"]["value"] = False
    json.dump(d, open(p, "w"), ensure_ascii=False, indent=4)
PY
    fi
    # Audio: re-probe snd-sc8280xp after ADSP, then apply the UCM verb + amps.
    chroot "$ROOTDIR" systemctl enable sheng-audio-rebind.service 2>/dev/null || true
    chroot "$ROOTDIR" systemctl enable sheng-audio-ucm.service 2>/dev/null || true
    # USB gadget network (self-skips on units with no UDC).
    chroot "$ROOTDIR" systemctl enable usb-gadget-net.service 2>/dev/null || true
    chroot "$ROOTDIR" systemctl enable ssh 2>/dev/null || chroot "$ROOTDIR" systemctl enable sshd 2>/dev/null || true
    # Bluetooth HID (mice/keyboards) goes through uhid (BLE) / hidp (BR-EDR);
    # both are modules and auto-loaded by nothing, so after pairing a mouse can't
    # connect. Load them at boot.
    printf 'uhid\nhidp\n' > "$ROOTDIR/etc/modules-load.d/sheng-bluetooth-hid.conf"
    printf '\nDeepin (sheng)： ssh %s@<平板IP>  (走 WiFi；或 USB 网络 192.168.42.15)\n\n' "$USER_NAME" \
        > "$ROOTDIR/etc/issue"

    # 6. Users + hostname + locale
    setup_users "$ROOTDIR" "$ROOT_PASS" "$USER_NAME" "$USER_PASS" \
        "sudo,audio,video,render,input,plugdev,netdev"
    # The greeter runs as the 'lightdm' user; it must be able to traverse the
    # home dir to read the user's qt-theme.ini UI scale (see greeters.d patch).
    chmod 711 "$ROOTDIR/home/$USER_NAME"
    echo "deepin-sheng-${MODE}" > "$ROOTDIR/etc/hostname"
    printf 'LANG=zh_CN.UTF-8\n' > "$ROOTDIR/etc/default/locale"
    printf 'zh_CN.UTF-8\n'       > "$ROOTDIR/etc/locale.conf" 2>/dev/null || true
    chroot "$ROOTDIR" ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true

    # 7. Autologin + default graphical target (best effort)
    setup_deepin_autologin "$ROOTDIR" "$USER_NAME"
    chroot "$ROOTDIR" systemctl set-default graphical.target 2>/dev/null || true

    # 8. fstab (bound by PARTLABEL, matches the boot.img cmdline)
    generate_fstab "$ROOTDIR" "$MODE"

    # 9. Unmount, stamp UUID, convert to Android sparse (.img).
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

echo "[OK] Deepin arm64 rootfs build complete!"
