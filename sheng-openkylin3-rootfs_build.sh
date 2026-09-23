#!/bin/bash
# =============================================================================
# sheng-openkylin3-rootfs_build.sh — openKylin 3.0 (huanghe) arm64 rootfs for
# Xiaomi Pad 6S Pro (sheng), built by EXTRACTING openKylin's official arm64
# image — the same "take the prebuilt userland, flatten to ext4, inject the
# sheng kernel/firmware, apply device quirks" approach as
# sheng-deepin-rootfs_build.sh.
# =============================================================================
# Why extract instead of bootstrap from the apt repo: openKylin's LIVE archive
# for 3.0 ("huanghe") is incomplete — several packages depend on packages that
# are not published (libeis1, user-session-migration, python3-watchdog), so the
# UKUI desktop cannot be installed from it via debootstrap/mmdebstrap. openKylin
# ships its OWN release image (built from a consistent snapshot); we take the
# userland from that instead.
#
# Supported image types (auto-detected by extension + magic):
#   *.iso          mount + unsquashfs the live filesystem (casper/live/…; picks
#                  up every *.squashfs, and honours /LIVE/filesystem.module)
#   *.img.xz/.gz   decompress, loop-mount the largest ext4 partition, rsync
#   *.tar.xz/.zst  tar -x            *.tar.gz/.tgz  tar -x
#   *.zip          unzip (recursing into a nested .img)
#
# Usage:
#   sudo bash sheng-openkylin3-rootfs_build.sh openkylin3-desktop 7.1 dual dde
#     args: <distro-variant> <kernel_version> [boot_mode: single|dual|all] [flavour]
# env:  OPENKYLIN_IMG_URL=<url>   (REQUIRED — the openKylin 3.0 arm64 image)
#       IMAGE_SIZE / UUID / ROOT_PASS / USER_PASS / USER_NAME / FIRMWARE_URL /
#       MIPPS_DEB_URL  (optional overrides)
#
# Output (one per boot mode):
#   openkylin_<ver>_<mode>_<ts>.img.gz   (Android-sparse ext4 rootfs, gzip)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/rootfs-common.sh"

# --- Configuration -----------------------------------------------------------
IMAGE_SIZE="${IMAGE_SIZE:-}"                            # empty => auto-size
UUID="${UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"    # repo default
OPENKYLIN_VERSION="${OPENKYLIN_VERSION:-3.0}"

# The openKylin arm64 release image. REQUIRED — set via env or the workflow
# input (openKylin's download page is JS-rendered, so we can't hardcode a stable
# URL; paste the "Desktop / ARM64 / 3.0" download link). ISO / .img.xz / .tar.*
# / .zip are all accepted — see fetch_rootfs below.
OPENKYLIN_IMG_URL="${OPENKYLIN_IMG_URL:-}"

ROOT_PASS="${ROOT_PASS:-1234}"
USER_PASS="${USER_PASS:-luser}"
USER_NAME="${USER_NAME:-luser}"
SYSTEM_HOSTNAME="${SYSTEM_HOSTNAME:-sheng}"
SYSTEM_LOCALE="${SYSTEM_LOCALE:-zh_CN.UTF-8}"
SYSTEM_TIMEZONE="${SYSTEM_TIMEZONE:-Asia/Shanghai}"

# --- Args --------------------------------------------------------------------
validate_args 2 4 $# '<distro-variant> <kernel_version> [boot_mode] [flavour]'
validate_root

DISTRO=$1
KERNEL=$2
TARGET_MODE=${3:-dual}
TARGET_FLAVOUR=${4:-dde}   # accepted for arg-contract parity (desktop is in the image)

[ -n "$OPENKYLIN_IMG_URL" ] || {
    echo "ERROR: OPENKYLIN_IMG_URL is not set. Point it at the openKylin 3.0" >&2
    echo "       arm64 release image (ISO / .img.xz / .tar.* / .zip)." >&2
    exit 1
}

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
        squashfs-tools zstd unzip rsync xz-utils util-linux aria2 pigz
fi

# --- Download the openKylin image once ---------------------------------------
DLDIR="$(mktemp -d)"
# Keep the URL's basename so the extension survives the download — fetch_rootfs
# dispatches on extension (.iso / .img.xz / .tar.xz / .zip).
src_name="$(basename "${OPENKYLIN_IMG_URL%%\?*}")"
{ [ -n "${src_name}" ] && [ "${src_name}" != "/" ]; } || src_name="openkylin-img"
src_file="${DLDIR}/${src_name}"
# Parallel download (aria2c) — the image is several GiB from openKylin's CDN
# (China), so a multi-connection fetch is markedly faster than single-stream wget.
if command -v aria2c >/dev/null 2>&1; then
    echo "==> Fetching openKylin image (aria2c -x16): ${OPENKYLIN_IMG_URL}"
    aria2c -x16 -s16 -k1M -c --max-tries=5 --retry-wait=3 \
        -d "$DLDIR" -o "$src_name" "$OPENKYLIN_IMG_URL"
else
    echo "==> Fetching openKylin image (wget): ${OPENKYLIN_IMG_URL}"
    wget -nv -O "${src_file}" "${OPENKYLIN_IMG_URL}"
fi
echo "==> Source size: $(du -h "${src_file}" | cut -f1)"

# fetch_rootfs <archive> <dest_dir>  — materialize the root filesystem tree
fetch_rootfs() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    case "$src" in
        *.iso)
            local mnt; mnt="$(mktemp -d)"
            mount -o loop,ro "$src" "$mnt"
            local sqs=() f n
            # Deepin-style: a /LIVE/filesystem.module lists the (possibly several)
            # squashfs that union into the live root. openKylin (Ubuntu-derived,
            # casper) ships a single casper/filesystem.squashfs and no module.
            local modf; modf="$(find "$mnt" -maxdepth 6 \( -iname 'filesystem.module' -o -iname 'filesystem-module' \) 2>/dev/null | head -1)"
            if [ -n "$modf" ] && [ -s "$modf" ]; then
                while IFS= read -r n; do
                    n="$(printf '%s' "$n" | tr -d '\r')"
                    [ -n "$n" ] || continue
                    f="$(dirname "$modf")/$n"
                    [ -f "$f" ] && sqs+=("$f")
                done < "$modf"
            fi
            if [ "${#sqs[@]}" -eq 0 ]; then
                # Any squashfs (casper/filesystem.squashfs, live/filesystem.squashfs,
                # filesystem-extra.squashfs, …), ordered so the main one is first.
                while IFS= read -r f; do sqs+=("$f"); done < \
                    <(find "$mnt" -maxdepth 6 -iname '*.squashfs' | sort)
            fi
            if [ "${#sqs[@]}" -eq 0 ]; then
                echo "ERROR: no *.squashfs found inside ISO" >&2
                umount "$mnt"; rmdir "$mnt"; return 1
            fi
            local sq
            for sq in "${sqs[@]}"; do
                echo "    squashfs: ${sq#"$mnt"/}"
                unsquashfs -f -d "$dest" -processors "$(nproc)" "$sq"
            done
            # Keep a live package manifest if present (for a dpkg-db rebuild).
            local pl; pl="$(find "$mnt" -maxdepth 6 \( -iname 'filesystem.manifest' -o -iname 'filesystem.packages' \) | head -1)"
            [ -n "$pl" ] && cp "$pl" "$dest/.live-manifest"
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
                echo "ERROR: unsupported image type: ${src} (file says: ${ft})" >&2
                echo "       pass a .iso / .img.xz / .tar.xz / .zip" >&2
                return 1
            fi
            ;;
    esac
}

# --- openKylin / lightdm autologin (UKUI uses lightdm + ukui-greeter) --------
setup_lightdm_autologin() {
    local rootdir="$1" user="$2"
    mkdir -p "$rootdir/etc/lightdm/lightdm.conf.d"
    cat > "$rootdir/etc/lightdm/lightdm.conf.d/00-sheng-autologin.conf" <<EOF
[Seat:*]
autologin-user=${user}
autologin-user-timeout=0
EOF
}

# --- Extract once up front (so we can size the image to fit) -----------------
echo "==> Extracting openKylin userland..."
STAGE="$(mktemp -d)"
fetch_rootfs "$src_file" "$STAGE"

# A live image usually ships an intact /var/lib/dpkg; only rebuild an empty one
# from the live manifest (keeps dpkg/apt usable on the disk root).
if [ ! -s "$STAGE/var/lib/dpkg/status" ] && [ -s "$STAGE/.live-manifest" ]; then
    echo "==> Rebuilding dpkg database from the live manifest..."
    mkdir -p "$STAGE/var/lib/dpkg/info" "$STAGE/var/lib/dpkg/updates" \
             "$STAGE/var/lib/dpkg/triggers" "$STAGE/var/lib/dpkg/alternatives" \
             "$STAGE/var/lib/apt/lists/partial" "$STAGE/var/cache/apt/archives/partial"
    : > "$STAGE/var/lib/dpkg/status"
    # casper manifest lines: "pkg<TAB>version<TAB>arch" (install ok installed)
    while IFS=$'\t' read -r name ver arch; do
        [ -n "$name" ] || continue
        [ -n "${arch:-}" ] || arch="arm64"
        printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nSection: unknown\nInstalled-Size: 0\nMaintainer: unknown\nArchitecture: %s\nVersion: %s\nDescription: (from live manifest)\n\n' \
            "$name" "$arch" "$ver" >> "$STAGE/var/lib/dpkg/status"
    done < "$STAGE/.live-manifest"
fi
rm -f "$STAGE/.live-manifest"

rm -rf "$DLDIR"          # reclaim the downloaded image
extracted_mb=$(du -sm "$STAGE" | cut -f1)
echo "==> Extracted rootfs: ${extracted_mb} MiB"

if [ -z "$IMAGE_SIZE" ]; then
    IMAGE_SIZE="$((extracted_mb + 2048))M"
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

    # 2. Flatten the extracted userland into the image (preserve perms/xattrs).
    echo "==> Copying userland into ${ROOTFS_IMG}..."
    rsync -aHAX --numeric-ids "$STAGE/" "$ROOTDIR/"

    MODES_LEFT=$((MODES_LEFT - 1))
    [ "$MODES_LEFT" -eq 0 ] && rm -rf "$STAGE"

    # 3. DNS inside chroot (seed from the runner; public DNS as fallback).
    {
        grep -E '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null || true
        echo 'nameserver 8.8.8.8'
        echo 'nameserver 1.1.1.1'
    } > "$ROOTDIR/etc/resolv.conf"

    # 4. Inject the sheng kernel .deb (placed in cwd by the workflow)
    echo "==> Injecting sheng kernel .deb..."
    inject_deb_kernel "$ROOTDIR" "./*.deb"

    # 4b. Firmware: two problems with the firmware-xiaomi-sheng .deb — it lands
    #     blobs under /usr/lib/<driver>/ (the kernel only searches /lib/firmware/)
    #     and it omits the Adreno GPU firmware (qcom/a740_sqe.fw +
    #     qcom/gmu_gen70200.bin). Copy the deb's blobs into /lib/firmware/ then
    #     overlay the full source-repo firmware set.
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

    # 4c. Xiaomi MIPPS 120W charger authentication.
    echo "==> Installing Xiaomi MIPPS auth (120W charging)..."
    _mipps="$(mktemp -d)/mipps.deb"
    if wget -nv -O "$_mipps" "${MIPPS_DEB_URL:-https://github.com/sonicepro/deepin-sheng-port/releases/download/kernel-bundle-7.1/xiaomi-mipps-auth.deb}"; then
        dpkg-deb --fsys-tarfile "$_mipps" | tar -x --keep-directory-symlink -C "$ROOTDIR/"
        echo "    installed /usr/libexec/xiaomi-mipps-auth (+ service + udev rule)"
    else
        echo "    WARN: MIPPS deb download failed; 120W charging auth skipped" >&2
    fi
    rm -rf "$(dirname "$_mipps")"

    # 5. Device quirks (shared helpers).
    setup_qrtr_service "$ROOTDIR"
    if [ ! -e "$ROOTDIR/usr/bin/qrtr-ns" ]; then
        mkdir -p "$ROOTDIR/etc/systemd/system/qrtr-ns.service.d"
        printf '[Unit]\nConditionPathExists=/usr/bin/qrtr-ns\n' \
            > "$ROOTDIR/etc/systemd/system/qrtr-ns.service.d/10-skip-if-absent.conf"
    fi
    configure_touchscreen "$ROOTDIR"
    fix_wifi_firmware "$ROOTDIR"

    # Bluetooth HID (mice/keyboards): uhid (BLE) / hidp (BR-EDR) modules.
    printf 'uhid\nhidp\n' > "$ROOTDIR/etc/modules-load.d/sheng-bluetooth-hid.conf"

    # Drop any NetworkManager connections the image shipped (foreign profiles).
    rm -f "$ROOTDIR"/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true

    # 5b. Generic device overlay (NM wifi MAC pin + hide-small-partitions udev).
    if [ -d "$SCRIPT_DIR/system_files_openkylin" ]; then
        cp -a "$SCRIPT_DIR/system_files_openkylin/." "$ROOTDIR/"
        chmod 0755 "$ROOTDIR"/usr/local/sbin/*.sh 2>/dev/null || true
    fi

    # 6. Users + hostname + locale + timezone.
    setup_users "$ROOTDIR" "$ROOT_PASS" "$USER_NAME" "$USER_PASS" \
        "sudo,audio,video,render,input,plugdev,netdev,network"
    echo "${SYSTEM_HOSTNAME}" > "$ROOTDIR/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$SYSTEM_HOSTNAME" > "$ROOTDIR/etc/hosts"
    printf 'LANG=%s\n' "$SYSTEM_LOCALE" > "$ROOTDIR/etc/default/locale"
    printf '%s\n'        "$SYSTEM_LOCALE" > "$ROOTDIR/etc/locale.conf" 2>/dev/null || true
    {
        printf '%s UTF-8\n' "$SYSTEM_LOCALE"
        printf 'en_US.UTF-8 UTF-8\n'
    } >> "$ROOTDIR/etc/locale.gen"
    chroot "$ROOTDIR" locale-gen >/dev/null 2>&1 || true
    chroot "$ROOTDIR" ln -sf "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" /etc/localtime 2>/dev/null || true
    printf '%s\n' "$SYSTEM_TIMEZONE" > "$ROOTDIR/etc/timezone"

    # 7. Autologin + services + default graphical target (best effort).
    setup_lightdm_autologin "$ROOTDIR" "$USER_NAME"
    chroot "$ROOTDIR" systemctl enable NetworkManager 2>/dev/null || true
    chroot "$ROOTDIR" systemctl enable ssh  2>/dev/null || chroot "$ROOTDIR" systemctl enable sshd 2>/dev/null || true
    chroot "$ROOTDIR" systemctl set-default graphical.target 2>/dev/null || true

    # 8. fstab (bound by PARTLABEL, matches the boot.img cmdline)
    generate_fstab "$ROOTDIR" "$MODE"

    # 9. Unmount, stamp UUID, convert to Android sparse (.img) + gzip.
    teardown_mounts "$ROOTDIR"
    apply_fs_uuid "$UUID" "$ROOTFS_IMG"
    echo "==> Converting ${ROOTFS_IMG} to Android sparse + gzip..."
    img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
    rm -f "$ROOTFS_IMG"
    # Parallel gzip (pigz, all cores) — the sparse image compresses well.
    if command -v pigz >/dev/null 2>&1; then
        pigz -4 "sparse_${ROOTFS_IMG}"
    else
        gzip -6 "sparse_${ROOTFS_IMG}"
    fi
    mv "sparse_${ROOTFS_IMG}.gz" "${ROOTFS_IMG}.gz"
    echo "==> Image: ${ROOTFS_IMG}.gz ($(du -h "${ROOTFS_IMG}.gz" | cut -f1))  (gzip -d -> ${ROOTFS_IMG})"

    echo "[MODE=$MODE] 完成！"
done

echo "[OK] openKylin arm64 rootfs build (from image) complete!"
