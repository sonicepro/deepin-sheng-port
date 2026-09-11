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
# Default source: an INSTALLED Deepin arm64 image (NOT the live ISO). The live
# ISO's squashfs root tends to hang in the systemd phase when used as a disk
# root; a board image is a real installed system. Rock5 (.img.xz, ext4 root) is
# the default; override with DEEPIN_SRC_URL. Alternatives:
#   .../releases/25.2.0/arm64/deepin-desktop-community-25.2.0-arm64.iso  (live ISO)
#   .../arm64/rubik-pi-3/FlatBuild_RUBIKPi_deepin25.desktop.zip          (Qualcomm board)
DEEPIN_SRC_URL="${DEEPIN_SRC_URL:-https://cdimage.deepin.com/arm64/rock5/deepin-crimson-arm64-rock-5-itx-desktop.img.xz}"

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
            local sq; sq="$(find "$mnt" -maxdepth 6 -name 'filesystem.squashfs' | head -1)"
            if [ -z "$sq" ]; then
                echo "ERROR: no filesystem.squashfs found inside ISO" >&2
                umount "$mnt"; rmdir "$mnt"; return 1
            fi
            echo "    squashfs: ${sq#"$mnt"/}"
            unsquashfs -f -d "$dest" "$sq"
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

# --- Extract once up front (so we can size the image to fit) -----------------
echo "==> Extracting Deepin userland..."
STAGE="$(mktemp -d)"
fetch_rootfs "$src_file" "$STAGE"
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

    # Free the staging tree before the (space-hungry) sparse pack, unless a
    # later boot mode still needs it.
    MODES_LEFT=$((MODES_LEFT - 1))
    [ "$MODES_LEFT" -eq 0 ] && rm -rf "$STAGE"

    # 3. DNS inside chroot
    setup_dns "$ROOTDIR" 223.5.5.5 1.1.1.1 8.8.8.8

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

    # 5c. Device system files + device services.
    if [ -d "$SCRIPT_DIR/system_files" ]; then
        cp -a "$SCRIPT_DIR/system_files/." "$ROOTDIR/"
        # git may not preserve the exec bit -> make the helper scripts runnable
        chmod 0755 "$ROOTDIR"/usr/local/sbin/*.sh 2>/dev/null || true
    fi
    # WirePlumber on Deepin defaults to ACP instead of UCM, so this card exposes
    # no UCM profile (only "off"/"pro-audio") -> PipeWire falls back to a Dummy
    # output. Flip it to the UCM path so the real ALSA sinks appear.
    _wp="$ROOTDIR/usr/share/wireplumber/scripts/monitors/alsa.lua"
    if [ -f "$_wp" ]; then
        sed -i '/api\.alsa\.use-acp/ s/= true/= false/' "$_wp"
    fi
    chroot "$ROOTDIR" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y openssh-server" >/dev/null 2>&1 || true
    # Audio: re-probe snd-sc8280xp after ADSP, then apply the UCM verb + amps.
    chroot "$ROOTDIR" systemctl enable sheng-audio-rebind.service 2>/dev/null || true
    chroot "$ROOTDIR" systemctl enable sheng-audio-ucm.service 2>/dev/null || true
    # USB gadget network (self-skips on units with no UDC).
    chroot "$ROOTDIR" systemctl enable usb-gadget-net.service 2>/dev/null || true
    chroot "$ROOTDIR" systemctl enable ssh 2>/dev/null || chroot "$ROOTDIR" systemctl enable sshd 2>/dev/null || true
    printf '\nDeepin (sheng)： ssh %s@<平板IP>  (走 WiFi；或 USB 网络 192.168.42.15)\n\n' "$USER_NAME" \
        > "$ROOTDIR/etc/issue"

    # 6. Users + hostname + locale
    setup_users "$ROOTDIR" "$ROOT_PASS" "$USER_NAME" "$USER_PASS" \
        "sudo,audio,video,render,input,plugdev,netdev"
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
