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
# Drop into a fork of code002-2/Xiaomi-pad-6s-pro-Linux (branch "sheng"),
# at repo root, next to lib/rootfs-common.sh. Driven by
# .github/workflows/build-deepin.yml (runs-on: ubuntu-24.04-arm).
#
# Supported sources (auto-detected by extension), override with DEEPIN_SRC_URL:
#   *.iso         official arm64 ISO   -> unsquashfs the live filesystem
#   *.tar.xz/.zst deepin-ports flat     -> tar -x
#   *.img.xz/.gz  board image           -> decompress, mount ext4 part, rsync
#   *.zip         FlatBuild             -> unzip
#
# Usage (same arg contract as sheng-rootfs_build.sh):
#   sudo bash sheng-deepin-rootfs_build.sh deepin-desktop 7.1 all all
#     args: <distro-variant> <kernel_version> [boot_mode: all|dual|single] [flavour]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rootfs-common.sh"

# --- Configuration -----------------------------------------------------------
IMAGE_SIZE="${IMAGE_SIZE:-12G}"
UUID="${UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"   # repo default
DEEPIN_VERSION="${DEEPIN_VERSION:-25.2.0}"
# Official generic arm64 userland. Its chip list is Phytium/Kunpeng (server),
# but the *userland* is plain arm64 (ARMv8-A baseline) and runs on SM8550.
# For a cleaner installed system, point this at a deepin-ports flat rootfs or a
# board image, e.g.:
#   DEEPIN_SRC_URL=https://cdimage.deepin.com/arm64/rock5/deepin-crimson-arm64-rock-5-itx-desktop.img.xz
DEEPIN_SRC_URL="${DEEPIN_SRC_URL:-https://cdimage.deepin.com/releases/${DEEPIN_VERSION}/arm64/deepin-desktop-community-${DEEPIN_VERSION}-arm64.iso}"

ROOT_PASS="${ROOT_PASS:-1234}"
USER_PASS="${USER_PASS:-luser}"
USER_NAME="${USER_NAME:-luser}"

# --- Args --------------------------------------------------------------------
validate_args 2 4 $# '<distro-variant> <kernel_version> [boot_mode] [desktop_env]'
validate_root

DISTRO=$1
KERNEL=$2
TARGET_MODE=${3:-all}
TARGET_FLAVOUR=${4:-all}   # Deepin has a single DE (DDE); accepted and ignored

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

# --- Download the Deepin source once, reused across boot modes --------------
STAGE_DL="$(mktemp -d)"
src_file="${STAGE_DL}/deepin-src"
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
            local sq; sq="$(find "$mnt" -maxdepth 5 -name 'filesystem.squashfs' | head -1)"
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
            local part=""
            for p in "${loop}"p*; do
                [ -b "$p" ] || continue
                if [ "$(blkid -o value -s TYPE "$p" 2>/dev/null || true)" = "ext4" ]; then
                    part="$p"
                fi
            done
            if [ -z "$part" ]; then
                echo "ERROR: no ext4 partition in image (is it Deepin?)" >&2
                losetup -d "$loop"; return 1
            fi
            echo "    root partition: ${part}"
            mount -o ro "$part" "${tmpd}/mnt"
            rsync -aHAX --numeric-ids "${tmpd}/mnt/" "$dest/"
            umount "${tmpd}/mnt"
            losetup -d "$loop"
            rm -rf "$tmpd"
            ;;
        *.zip)
            unzip -q "$src" -d "$dest"
            # Some FlatBuilds wrap the tree in a single top dir or an .img
            local nested_img; nested_img="$(find "$dest" -maxdepth 2 -name '*.img' | head -1)"
            if [ -n "$nested_img" ] && [ "$(find "$dest" -maxdepth 1 -mindepth 1 | wc -l)" -le 2 ]; then
                local redo; redo="$(mktemp -d)"
                fetch_rootfs "$nested_img" "$redo"
                rm -rf "$dest"; mv "$redo" "$dest"
            fi
            ;;
        *)
            echo "ERROR: unsupported archive type: ${src}" >&2
            return 1
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

# --- Build loop over boot modes ---------------------------------------------
mapfile -t BOOTMODES < <(parse_boot_modes "$TARGET_MODE") || exit 1

for MODE in "${BOOTMODES[@]}"; do
    echo ""
    echo "======================================================"
    echo "构建 Deepin ${DEEPIN_VERSION} | 模式: $MODE"
    echo "======================================================"

    preflight_checks 15360

    ROOTFS_IMG="deepin_${DEEPIN_VERSION}_${MODE}_${TIMESTAMP}.img"

    # 1. Create the ext4 image and mount it at $ROOTDIR
    create_image "$IMAGE_SIZE" "$ROOTFS_IMG" "$UUID"
    setup_chroot_mounts "$ROOTDIR"
    trap_teardown "$ROOTDIR"

    # 2. Extract the Deepin userland into a staging dir
    echo "==> Extracting Deepin userland..."
    STAGE="$(mktemp -d)"
    fetch_rootfs "$src_file" "$STAGE"

    # 3. Flatten it into the image (preserve perms/xattrs/hardlinks)
    echo "==> Copying userland into ${ROOTFS_IMG}..."
    rsync -aHAX --numeric-ids --info=progress2 "$STAGE/" "$ROOTDIR/"
    rm -rf "$STAGE"

    # 4. DNS inside chroot
    setup_dns "$ROOTDIR" 223.5.5.5 1.1.1.1 8.8.8.8

    # 5. Inject the sheng kernel .deb (placed in cwd by _rootfs-template.yml)
    echo "==> Injecting sheng kernel .deb..."
    inject_deb_kernel "$ROOTDIR" "./*.deb"

    # 6. Device quirks (shared with the other distro scripts)
    setup_getty_ttyMSM0 "$ROOTDIR"
    setup_qrtr_service "$ROOTDIR"
    configure_touchscreen "$ROOTDIR"
    fix_wifi_firmware "$ROOTDIR"

    # 7. Users + hostname + locale
    setup_users "$ROOTDIR" "$ROOT_PASS" "$USER_NAME" "$USER_PASS" \
        "sudo,audio,video,render,input,plugdev,netdev"
    echo "deepin-sheng-${MODE}" > "$ROOTDIR/etc/hostname"
    printf 'LANG=zh_CN.UTF-8\n' > "$ROOTDIR/etc/default/locale"
    printf 'zh_CN.UTF-8\n'       > "$ROOTDIR/etc/locale.conf" 2>/dev/null || true
    chroot "$ROOTDIR" ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true

    # 8. Autologin + default graphical target (best effort)
    setup_deepin_autologin "$ROOTDIR" "$USER_NAME"
    chroot "$ROOTDIR" systemctl set-default graphical.target 2>/dev/null || true

    # 9. fstab (bound by PARTLABEL, matches the boot.img cmdline)
    generate_fstab "$ROOTDIR" "$MODE"

    # 10. Unmount, stamp UUID, pack sparse + 7z
    teardown_mounts "$ROOTDIR"
    apply_fs_uuid "$UUID" "$ROOTFS_IMG"
    echo "==> Packing sparse ${ROOTFS_IMG} -> ${ROOTFS_IMG%.img}.7z"
    pack_sparse_image "$ROOTFS_IMG" "${ROOTFS_IMG%.img}.7z"

    echo "[MODE=$MODE] 完成！"
done

rm -rf "$STAGE_DL"
echo "[OK] Deepin arm64 rootfs build complete!"
