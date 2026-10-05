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
#       REMOVE_AI=1    (optional — strip the Kylin AI stack from the extracted
#                       image; keeps the desktop-critical AI client libs)
#       LINGLONG_ENV=0 (optional — skip installing the Linyaps runtime env
#                       (ll-cli/ll-box + its Qt5/repo/libyaml-cpp fixes); default: on)
#       AUTOROTATE_ENV=0 (optional — skip the auto-rotate setup: pd-mapper +
#                       adsprpcd-sensorspd + the sheng-autorotate daemon); default: on
#       BRIGHTNESS_FIX_ENV=0 (optional — skip patching ukui-settings-daemon so the
#                       compositor gamma-manager owns screen brightness (no
#                       reset-to-max on rotation / boot)); default: on
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

# 移除镜像里的 Kylin AI 栈（AI 助手/机器人、后端服务、推理引擎、约 1.3G 模型）。
# 默认关闭；设 REMOVE_AI=1（或 workflow 的 remove_ai 输入）开启。桌面硬依赖的
# AI 客户端库会保留，见 lib/rootfs-common.sh 的 remove_kylin_ai。
REMOVE_AI="${REMOVE_AI:-0}"

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

# --- 如意玲珑 (Linyaps) 运行环境 --------------------------------------------
# 目标：让 ll-cli / ll-box 在本镜像里可用（能装、能跑玲珑 app）。**不含商店本体**。
# 以下每条都在真机逐一验证过：
#   1) 镜像自带 Qt5 是 nile(2.0) 构建 (5.15.10+dfsg-3ok2.17) 跑在 huanghe 上 → 自带
#      的旧 ll-cli(1.5.7) 一碰 D-Bus 就 SIGSEGV。升到 huanghe 重建版 3ok2.18。
#   2) 官方 linyaps OBS 的 openkylin_3.0 / openkylin_2.0 目标**只有 amd64**（无
#      arm64）→ 装 arm64 的 Deepin_25 目标（玲珑 1.14，改用 Qt6；本镜像 Qt6
#      6.10.2 正合适）。
#   3) linyaps 1.14 依赖 libyaml-cpp0.7，openKylin 只有 0.8 → 从 Debian 取 arm64 deb。
#   4) linglong-box 必须显式装 2.2.1：装 linglong-bin 的依赖是 "linglong-box |
#      crun"，系统已有 crun 时 apt 不会升级 linglong-box → /usr/bin/ll-box 仍是
#      1.5.7，不认 1.14 用的 --root（daemon 日志：ll-box: unrecognized option
#      '--root'）→ app 起不来（ll-cli 只笼统报 InitRunContext failed）。
#   5) deepin 的 linglong-bin postinst 有个空的 for/done 循环（debhelper 生成时
#      unit 列表为空），/bin/sh(dash) 语法报错 → 包卡在半配置 → 需打补丁后再
#      dpkg --configure -a。
#   6) 镜像根的 / 与 /etc 属主是 uid 1001（非 root）→ systemd-tmpfiles 对所有规则
#      报 "unsafe path transition" 直接跳过 → /run/linglong 被建成 755 root 而非
#      1777 deepin-linglong → ll-cli run 报 "failed to create directory: 权限不够"。
#      把 / /etc 归一成 root，tmpfiles 才会正确建 /run/linglong。
LINGLONG_ENV="${LINGLONG_ENV:-1}"          # 0 = 跳过整节
LINGLONG_REPO_URL="${LINGLONG_REPO_URL:-https://ci.deepin.com/repo/obs/linglong:/CI:/release/Deepin_25/}"
LIBYAML_CPP07_URL="${LIBYAML_CPP07_URL:-http://deb.debian.org/debian/pool/main/y/yaml-cpp/libyaml-cpp0.7_0.7.0+dfsg-8+b1_arm64.deb}"

install_linglong_env() {
    local rootdir="$1"
    echo "==> 安装如意玲珑 (Linyaps) 运行环境..."

    # (1) 修镜像属主：/ 与 /etc 归一为 root（否则 systemd-tmpfiles 跳过 linglong.conf，
    #     /run/linglong 权限会不对 → 玲珑 app 起不来）。
    chown 0:0 "$rootdir" "$rootdir/etc" 2>/dev/null || true

    # (2) chroot 内加 arm64 的 linyaps 源（openkylin_* 目标无 arm64，用 Deepin_25）。
    mkdir -p "$rootdir/etc/apt/sources.list.d"
    printf 'deb [trusted=yes arch=arm64] %s ./\n' "$LINGLONG_REPO_URL" \
        > "$rootdir/etc/apt/sources.list.d/linglong.list"

    # (2b) Qt5 升到 huanghe 重建版（修旧 ll-cli 的 D-Bus 段错误 + 所有 Qt5 应用）。
    #      best effort：拿不到就跳过。
    chroot "$rootdir" bash -c "export DEBIAN_FRONTEND=noninteractive; \
        apt-get update -qq 2>/dev/null || true; \
        apt-get install -y --only-upgrade \
            libqt5core5a libqt5dbus5 libqt5gui5 libqt5network5 libqt5widgets5 \
            2>/dev/null || true"

    # (3) libyaml-cpp0.7（openKylin 只有 0.8）——宿主下载，chroot 内 dpkg -i。
    local tmpd; tmpd="$(mktemp -d)"
    if wget -nv -O "$tmpd/libyaml-cpp0.7.deb" "$LIBYAML_CPP07_URL"; then
        install -Dm644 "$tmpd/libyaml-cpp0.7.deb" "$rootdir/tmp/libyaml-cpp0.7.deb" || true
        chroot "$rootdir" dpkg -i /tmp/libyaml-cpp0.7.deb || true
        rm -f "$rootdir/tmp/libyaml-cpp0.7.deb"
    else
        echo "   警告: libyaml-cpp0.7 下载失败，linyaps 可能因缺依赖装不上" >&2
    fi
    rm -rf "$tmpd"

    # (4) 装/升 linyaps。linglong-box 显式列上——别让 crun 顶替旧 ll-box。
    chroot "$rootdir" bash -c "export DEBIAN_FRONTEND=noninteractive; \
        apt-get update -qq 2>/dev/null || true; \
        apt-get install -y --no-install-recommends \
            linglong-bin linglong-installer linglong-box erofs-utils || true"

    # (5) 修 linglong-bin postinst 的空 for/done 循环（版本相关，用模式匹配：只删
    #     “do 紧跟 done”的空循环，保留带 body 的正常循环）。
    local pi="$rootdir/var/lib/dpkg/info/linglong-bin.postinst"
    if [ -f "$pi" ] && ! sh -n "$pi" 2>/dev/null && command -v perl >/dev/null 2>&1; then
        echo "   修补 linglong-bin.postinst 的空 for/done 循环"
        perl -0777 -i -pe 's/for\s+instance\s+in\s+\$instances;\s*do\s*done//g' "$pi" || true
    fi

    # (6) 收尾：配置所有待定包 + 启用玲珑守护进程 + 预建 /etc/linglong（/run/linglong
    #     是 tmpfs，开机会由已修好的 tmpfiles 重建为 1777）。
    chroot "$rootdir" bash -c "dpkg --configure -a >/dev/null 2>&1 || true; \
        systemctl enable org.deepin.linglong.PackageManager.service 2>/dev/null || true; \
        systemd-tmpfiles --create /usr/lib/tmpfiles.d/linglong.conf 2>/dev/null || true"

    # 验证：应能看到 ll-cli。
    local ver; ver="$(chroot "$rootdir" ll-cli --version 2>/dev/null || true)"
    if [ -n "$ver" ]; then
        echo "   如意玲珑环境完成：${ver}"
    else
        echo "   警告: 未检测到 ll-cli，如意玲珑环境可能没装好（检查 ci.deepin.com / deb.debian.org 是否可达）" >&2
    fi
}

# --- KMRE (Kylin Mobile Runtime Environment / Android) -----------------------
# 目标：刷机后 kmre 开箱即用（Android 能起、联网、装 apk、出图）。逐条真机验证：
#   1) openKylin 仓库没有 kmre 元包硬依赖的 kylin-kmre-image-update，且较新组件
#      依赖 libqt5core5t64（仓库只有非 t64）→ 造桩包 + 依赖钉版本
#      （/etc/apt/preferences.d/00-kmre 由覆盖层 system_files_openkylin 提供）。
#   2) kmre 的 systemd 单元在 /opt/system/lib/systemd/system/，靠 ostree 的
#      SYSTEMD_UNIT_PATH 才进 unit path；本系统非 ostree → 单元静默未启用 →
#      手动软链进 /etc/systemd/system 再 enable。
#   3) kmre daemon 用 docker CLI 起容器却不传 device-cgroup-rule / binderfs →
#      容器里 vold/dm EPERM。用 wrapper（run|create 注入）解决。
#   4) kylin-installer 用旧语法 `aapt badging` → wrapper 转 `aapt dump badging`。
#   5) 容器镜像自身的 32 位 boringssl/dex2oat/binder/vold/ethernet 补丁由
#      patch_kmre_image()（下方）覆盖到镜像 tar；本函数负责宿主侧安装。
KMRE_ENV="${KMRE_ENV:-1}"                   # 0 = 跳过整节
KMRE_STUB_VER="${KMRE_STUB_VER:-3.0-250506.10+250506.11}"
KMRE_IMAGE_OVERLAY="${KMRE_IMAGE_OVERLAY:-$SCRIPT_DIR/kmre_image_files.tar}"

# 给 kmre 容器镜像 tar 打补丁。上游 tar 是**未打补丁的原始镜像（2 层）**——缺
# 32 位 boringssl/dex2oat/binder/vold/ethernet 修复，直接刷机 Android 会重启循环、
# 无网。用本仓库的 kmre_image_files.tar（含实机已打好补丁的镜像文件）覆盖回去。
# 须在装完 kmre（tar 就位）后调用；CI runner 自带 docker（arm64 原生）。
patch_kmre_image() {
    local rootdir="$1"
    local tar="$rootdir/opt/system/resource/kmre/kmre-container-image.tar"
    local conf="$rootdir/opt/system/resource/kmre/kmre.conf"
    [ -f "$tar" ]  || { echo "   跳过: 未找到 $tar" >&2; return 0; }
    [ -f "$KMRE_IMAGE_OVERLAY" ] || { echo "   跳过: 未找到 $KMRE_IMAGE_OVERLAY" >&2; return 0; }
    command -v docker >/dev/null 2>&1 || {
        echo "   跳过: 环境无 docker，无法补 kmre 镜像（新刷机会重启循环！）" >&2; return 0; }
    local repo tag image
    repo="$(sed -n 's/^repo=//p' "$conf" | head -1)"; repo="${repo:-kmre3}"
    tag="$(sed -n 's/^tag=//p' "$conf" | head -1)"
    image="${repo}:${tag}"
    echo "   补 kmre 容器镜像 ${image}（覆盖 32 位/binder/ethernet 修复）..."
    docker load -i "$tar" >/dev/null
    local cid; cid="$(docker create --platform linux/arm64 "$image")"
    docker cp "$KMRE_IMAGE_OVERLAY" "$cid:/"
    docker commit "$cid" "$image" >/dev/null
    docker rm "$cid" >/dev/null
    docker save "$image" -o "$tar"
    echo "   kmre 容器镜像已重打（$(du -h "$tar" | cut -f1)）"
}

install_kmre() {
    local rootdir="$1"
    echo "==> 安装 KMRE (麒麟移动运行环境 / Android)..."
    export DEBIAN_FRONTEND=noninteractive

    # 基础依赖（docker.io 把 CLI 装在 /opt/system/bin/docker，不是 /usr/bin）。
    chroot "$rootdir" apt-get update -qq 2>/dev/null || true
    chroot "$rootdir" apt-get install -y --no-install-recommends \
        docker.io dnsmasq aapt 2>/dev/null || true

    # 桩包 kylin-kmre-image-update（kmre 元包硬依赖，仓库不存在）。
    local sd; sd="$(mktemp -d)"
    mkdir -p "$sd/stub/DEBIAN"
    cat > "$sd/stub/DEBIAN/control" <<EOF
Package: kylin-kmre-image-update
Version: ${KMRE_STUB_VER}
Architecture: all
Maintainer: sheng-port <noreply@example.com>
Description: stub to satisfy the kmre meta dependency (image OTA only)
EOF
    dpkg-deb -b "$sd/stub" "$sd/kylin-kmre-image-update_${KMRE_STUB_VER}_all.deb" >/dev/null
    install -Dm644 "$sd/kylin-kmre-image-update_${KMRE_STUB_VER}_all.deb" \
        "$rootdir/tmp/kylin-kmre-image-update.deb"
    chroot "$rootdir" dpkg -i /tmp/kylin-kmre-image-update.deb >/dev/null 2>&1 || true
    rm -f "$rootdir/tmp/kylin-kmre-image-update.deb"; rm -rf "$sd"

    # 装 kmre 全家桶（apt pins 已在 /etc/apt/preferences.d/00-kmre）。
    chroot "$rootdir" apt-get update -qq 2>/dev/null || true
    chroot "$rootdir" apt-get install -y --no-install-recommends kmre \
        || echo "   警告: apt 装 kmre 失败（检查 openKylin 仓库是否可达）" >&2

    # docker CLI wrapper：/opt/system/bin/docker → docker.real + 注入脚本。
    if [ -f "$rootdir/opt/system/bin/docker" ] && [ ! -e "$rootdir/opt/system/bin/docker.real" ]; then
        mv "$rootdir/opt/system/bin/docker" "$rootdir/opt/system/bin/docker.real"
        install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/share/kmre/docker-wrapper" \
            "$rootdir/opt/system/bin/docker"
    fi

    # aapt wrapper（badging → dump badging）。
    if [ -e "$rootdir/usr/lib/android-sdk/build-tools/debian/aapt" ]; then
        install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/share/kmre/aapt-wrapper" \
            "$rootdir/usr/bin/aapt"
    fi

    # kmre-fixups: kmre daemon 运行中会把容器 CPU 配额**自行打回 1 核**
    #     （NanoCpus=1e9，因 SM8550 不在它硬编码的国产 CPU 白名单里）——于是每个
    #     app 冷启动都被节流卡住、过一会儿才恢复。服务用 0.25s 紧轮询把配额打回全核。
    #     显式安装并保可执行（overlay 的 cp -a 会保留源文件权限位，这里统一兜底），
    #     并断言是紧轮询版（缺 HK_TICKS 就是旧版，构建要能看见告警）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/sbin/kmre-fixups.sh" \
        "$rootdir/usr/local/sbin/kmre-fixups.sh"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/system/kmre-fixups.service" \
        "$rootdir/etc/systemd/system/kmre-fixups.service"
    if ! grep -q 'HK_TICKS' "$rootdir/usr/local/sbin/kmre-fixups.sh"; then
        echo "   警告: kmre-fixups.sh 不是紧轮询版（缺 HK_TICKS 标记）" >&2
    fi

    # 软链 kmre 的 systemd 单元进 unit path。
    local u
    for u in docker.socket docker.service kylin-kmre-daemon.service kylin-kmre-exagear-register.service; do
        [ -e "$rootdir/opt/system/lib/systemd/system/$u" ] && \
            ln -sf "/opt/system/lib/systemd/system/$u" "$rootdir/etc/systemd/system/$u"
    done

    # enable 服务（chroot 内 systemctl；policy-rc.d 阻止真正启动）。
    printf '#!/bin/sh\nexit 101\n' > "$rootdir/usr/sbin/policy-rc.d"
    chmod 0755 "$rootdir/usr/sbin/policy-rc.d" 2>/dev/null || true
    chroot "$rootdir" systemctl enable \
        docker.socket docker.service containerd \
        kylin-kmre-daemon.service kmre-binder.service kmre-fixups.service \
        kmre-zram.service dnsmasq \
        2>/dev/null || true
    rm -f "$rootdir/usr/sbin/policy-rc.d"

    # 6) 给容器镜像 tar 打补丁（32 位/binder/ethernet 修复），否则新刷机重启循环。
    patch_kmre_image "$rootdir"

    echo "   KMRE 安装完成"
}

# --- 自动转屏 (auto-rotate: ADSP SSC 加速度计 -> UKUI 转屏) --------------------
# 目标：刷机后平板自动转屏开箱即用。链条与根因（真机逐一验证）：
#   1) openKylin 转屏功能 = 会话 D-Bus com.kylin.statusmanager.interface 的
#      set_rotation(orientation, who, why)；取值 normal/left/right/upside-down。
#   2) 设备传感器 = ADSP SSC 加速度计（icm4x6xx），走 libssc（QMI over QRTR）。
#      之前 QRTR 上没有 SSC service(0x190/400)、ssccli 报 "SSC QMI Service not
#      found"。**根因**：ADSP 的传感器 PD 要等 AP 侧 servreg 就绪（pd-mapper）
#      加 adsprpcd 拉起 sensorspd 才会注册该 service —— 缺 protection-domain-mapper。
#   3) openKylin 自带自动转屏走 Qt5 Sensors→iio-sensor-proxy→libssc，但本机固件
#      的加速度计没有 measurement_id（mount-matrix 也全 0），iio-sensor-proxy 3.8
#      在 src/drv-ssc-accel.c:121 断言失败 → core dump → isSupportedAutoRotation()
#      恒 false。故改用本仓库自带的 sheng-autorotate 守护进程直连 ssccli。
#   依赖 install_touch_processor（它落地 libssc/ssccli）——须在其后调用。
#   镜像自带 /usr/bin/adsprpcd（无包属主）+ adsprpcd-sensorspd.service，但前者
#   缺可执行位、后者未 enable。AUTOROTATE_ENV=0 可跳过。
AUTOROTATE_ENV="${AUTOROTATE_ENV:-1}"

install_autorotate() {
    local rootdir="$1" uname="$2"
    echo "==> 配置自动转屏 (SSC 加速度计 -> openKylin 转屏)..."

    # (1) pd-mapper：AP 侧 servreg，ADSP 才能把传感器 PD 带起来、注册 SSC QMI。
    export DEBIAN_FRONTEND=noninteractive
    chroot "$rootdir" apt-get update -qq 2>/dev/null || true
    chroot "$rootdir" apt-get install -y --no-install-recommends \
        protection-domain-mapper qrtr-tools rmtfs 2>/dev/null \
        || echo "   警告: 装 protection-domain-mapper 失败（检查 openKylin 仓库是否可达）" >&2

    # (2) enable pd-mapper（apt postinst 一般已 enable，这里兜底）。rmtfs 无 modem
    #     时会起不来（无害），一并 enable 保持与真机一致。
    chroot "$rootdir" systemctl enable pd-mapper rmtfs 2>/dev/null || true

    # (3) 修正 /usr/bin/adsprpcd 的可执行位（镜像里是 0644 → ExecStart 203/EXEC）。
    if [ -f "$rootdir/usr/bin/adsprpcd" ]; then
        chmod 0755 "$rootdir/usr/bin/adsprpcd"
    else
        echo "   警告: 未找到 /usr/bin/adsprpcd，ADSP sensorspd 无法加载，自动转屏会失效" >&2
    fi

    # (4) enable adsprpcd-sensorspd.service，并挂到 multi-user.target（开机即拉起
    #     传感器 PD，不等 iio-sensor-proxy 触发）。
    chroot "$rootdir" systemctl enable adsprpcd-sensorspd.service 2>/dev/null || true
    chroot "$rootdir" systemctl add-wants multi-user.target adsprpcd-sensorspd.service 2>/dev/null || true

    # (5) 落地守护进程 + udev 规则（显式安装保证权限位；overlay 的 cp -a 已拷贝过）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-autorotate" \
        "$rootdir/usr/local/bin/sheng-autorotate"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/udev/rules.d/70-sheng-fastrpc.rules" \
        "$rootdir/etc/udev/rules.d/70-sheng-fastrpc.rules"

    # (6) 用户级 systemd 服务：装到 /etc/systemd/user（对所有用户枚举可见），并为该
    #     用户建 enable 软链（构建期没有用户 session，systemctl --user enable 用不了）。
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/user/sheng-autorotate.service" \
        "$rootdir/etc/systemd/user/sheng-autorotate.service"
    local udir="$rootdir/home/${uname}/.config/systemd/user"
    local target
    for target in default.target graphical-session.target; do
        mkdir -p "$udir/${target}.wants"
        ln -sf "/etc/systemd/user/sheng-autorotate.service" \
            "$udir/${target}.wants/sheng-autorotate.service"
    done
    chown -R "${uname}:${uname}" "$rootdir/home/${uname}/.config" 2>/dev/null || true

    echo "   自动转屏配置完成"
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

# --- 指纹 (Xiaomi Pad 6S Pro 电源键指纹 / FPC1553) --------------------------
# 目标：刷机后指纹开箱即用 —— 控制中心/锁屏能录入、**按住即解锁**、**休眠不被指纹打断**。
# 这条链既不是 openKylin 自带、也不是上游 Debian 的现成方案，是本仓库在真机上逐条
# 打通的（详见 DEVELOPMENT.md 的“指纹”一节）：
#   1) 上游 ianchb/xiaomi-sheng-fingerprint 的**纯用户态** QTEE/Mink 栈
#      （qteesupplicant + libfpc1553-qtee.so + 一颗含 fpc1553 驱动的私有 libfprint）
#      —— 内核只需 `fpc1553` 驱动 + /dev/tee0。
#   2) openKylin 图形登录/锁屏**只认 Kylin `biometric-auth`**（不走 fprintd），而它的
#      多设备驱动发现是 USB 的、看不到非 USB 的 FPC1553。做法：把镜像里
#      `biometric-driver-community-multidevice` 的 goodixmoc.so 复制成 fpc1553.so 并把
#      .so 里烤死的驱动名 goodixmoc(@0x8430) 改成 fpc1553，再让驱动用兄弟目录里的私有
#      libfprint（含 fpc1553 驱动）——即服务 drop-in 的 FP_FPC1553=1 + LD_LIBRARY_PATH。
#   3) 两个自研补丁（预编译二进制在 fingerprint_payload/）：
#      - libfprint-2.so.2.0.0：改 fpc1553 驱动 wait_for_finger_lift，验证/识别匹配到即
#        上报（不再等抬手）但保留芯片 deep-sleep → **按住即解锁**。
#      - fpc1553.ko.zst：去掉内核模块里无条件的 irq_set_irq_wake（指纹 IRQ 不再是唤醒
#        源）→ **点休眠不再 1.8s 自唤醒**。（vermagic 须匹配注入的内核！）
# ⚠ 升级内核要重编 fpc1553.ko；升级 xiaomi-sheng-fingerprint 包会覆盖私有 libfprint。
FINGERPRINT_ENV="${FINGERPRINT_ENV:-1}"     # 0 = 跳过整节
FINGERPRINT_DEB_URL="${FINGERPRINT_DEB_URL:-https://github.com/ianchb/xiaomi-sheng-fingerprint/releases/download/v0.1.4/xiaomi-sheng-fingerprint_0.1.4_arm64.deb}"

install_fingerprint() {
    local rootdir="$1"
    echo "==> 安装指纹 (FPC1553 / 电源键指纹)..."

    # (1) 用户态栈：上游 deb 用 fsys-tarfile 解开塞进 rootfs（避开 fprintd/libgusb
    #     依赖 —— Kylin 原生路径用不上 fprintd，无需 chroot dpkg）。
    local tmpd; tmpd="$(mktemp -d)"
    if wget -nv -O "$tmpd/xsf.deb" "$FINGERPRINT_DEB_URL"; then
        dpkg-deb --fsys-tarfile "$tmpd/xsf.deb" \
            | tar -x --keep-directory-symlink -C "$rootdir/"
        echo "   装上 qteesupplicant + 后端 + 私有 libfprint + qtee-listeners + systemd 单元"
    else
        echo "   警告: xiaomi-sheng-fingerprint deb 下载失败，指纹跳过（检查 github.com 是否可达）" >&2
        rm -rf "$tmpd"; return 0
    fi
    rm -rf "$tmpd"

    # (2) 启用 QTEE supplicant + SFS 配置服务。
    chroot "$rootdir" systemctl enable sfsconfig.service qteesupplicant.service 2>/dev/null || true

    # (3) Kylin 多设备驱动接线：goodixmoc.so → fpc1553.so（改烤死的驱动名）。
    local src="$rootdir/usr/lib/biometric-authentication/drivers/goodixmoc.so"
    local dst="$rootdir/usr/lib/biometric-authentication/drivers/fpc1553.so"
    if [ -f "$src" ]; then
        cp -a "$src" "$dst"
        if python3 - "$dst" <<'PYEOF'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
if d[0x8430:0x8439] == b'goodixmoc':
    d[0x8430:0x8438] = b'fpc1553\x00'
    open(p, 'wb').write(d)
    sys.exit(0)
sys.exit(1)
PYEOF
        then
            echo "   fpc1553.so 驱动名已打（goodixmoc→fpc1553 @0x8430）"
        else
            echo "   警告: goodixmoc.so 偏移 0x8430 不是 'goodixmoc'（镜像版本变了吗？）——驱动名未打，指纹可能不生效" >&2
        fi
        local conf="$rootdir/etc/biometric-auth/biometric-drivers.conf"
        if [ -f "$conf" ] && ! grep -q '^\[fpc1553\]' "$conf"; then
            printf '\n' >> "$conf"
            cat "$SCRIPT_DIR/fingerprint_payload/drivers.conf.fpc1553" >> "$conf"
        fi
        install -Dm644 "$SCRIPT_DIR/fingerprint_payload/10-fpc1553.conf" \
            "$rootdir/etc/systemd/system/biometric-authentication.service.d/10-fpc1553.conf"
    else
        echo "   警告: 未找到 goodixmoc.so（镜像缺 biometric-driver-community-multidevice？）——指纹跳过" >&2
        return 0
    fi

    # (4) 私有 libfprint（按住即解锁版）——覆盖 deb 里的同名文件。
    if [ -f "$SCRIPT_DIR/fingerprint_payload/libfprint-2.so.2.0.0" ]; then
        install -Dm755 "$SCRIPT_DIR/fingerprint_payload/libfprint-2.so.2.0.0" \
            "$rootdir/usr/lib/xiaomi-sheng-fingerprint/libfprint-2.so.2.0.0"
        echo "   私有 libfprint 覆盖为『按住即解锁』版"
    fi

    # (5) 休眠修复：覆盖内核模块 fpc1553.ko（去掉 IRQ 唤醒源）。
    local kver; kver="$(detect_kernel_module_dir "$rootdir")"
    if [ -n "$kver" ] && [ -f "$SCRIPT_DIR/fingerprint_payload/fpc1553.ko.zst" ]; then
        local mdst="$rootdir/lib/modules/$kver/kernel/drivers/misc/fpc1553.ko.zst"
        if [ ! -d "$(dirname "$mdst")" ]; then
            mdst="$rootdir/usr/lib/modules/$kver/kernel/drivers/misc/fpc1553.ko.zst"
        fi
        if [ -d "$(dirname "$mdst")" ]; then
            install -Dm644 "$SCRIPT_DIR/fingerprint_payload/fpc1553.ko.zst" "$mdst"
            chroot "$rootdir" depmod -a "$kver" 2>/dev/null || true
            echo "   fpc1553.ko 覆盖（休眠修复），kver=$kver"
        else
            echo "   警告: 未找到 fpc1553.ko 的目标目录（kver=$kver）——休眠修复未应用" >&2
        fi
    else
        echo "   警告: 未定位到内核模块目录，跳过 fpc1553.ko 覆盖" >&2
    fi

    echo "   指纹安装完成（控制中心/锁屏可用；只保留 1 个模板最快）"
}

# --- openKylin 系统更新修复（非 ostree 系统） -------------------------
# 镜像的 openKylin 是 ostree 部署；我们是摊平 ext4，造成系统更新在真机上失败/版本串乱：
#   1) 更新拉通用内核（`linux-generic`）→ 其 postinst 跑 `ostree` 包的
#      `/etc/kernel/{postinst,postrm}.d/zz-ostree-update`，在非 ostree 系统上报
#      `system not ostree type` 并 exit 1 → 内核配置失败 → 整个更新失败。→ 改成 no-op。
#   2) 镜像自带的 `/usr/lib/system-info/kylin-system-version.conf` 是 0 字节 →
#      `kylin-system-updater` 取 `[SYSTEM]` 失败 → 界面把异常当版本串打印
#      （`No section:'SYSTEM'`）。→ 补 `[SYSTEM]` 段。
#   3) 通用内核对 sheng 无用（我们引导 sheng mainline），每次更新都换一套
#      （含 ~100MB initrd）→ hold 住。
fix_system_update() {
    local rootdir="$1"
    echo "==> 修 openKylin 系统更新（非 ostree 系统）..."

    # (1) ostree 内核钩子 → no-op（否则内核 postinst 在非 ostree 系统必败）。
    local h
    for h in "$rootdir/etc/kernel/postinst.d/zz-ostree-update" \
             "$rootdir/etc/kernel/postrm.d/zz-ostree-update"; do
        [ -f "$h" ] && printf '#!/bin/sh\n# sheng: no-op on non-ostree system\nexit 0\n' > "$h"
    done
    echo "   已把 zz-ostree-update 钩子改成 no-op"

    # (2) kylin-system-version.conf 空的就补 [SYSTEM]。
    local vf="$rootdir/usr/lib/system-info/kylin-system-version.conf"
    if [ -f "$vf" ] && [ ! -s "$vf" ]; then
        printf '[SYSTEM]\nos_version = 3.0\nupdate_version = 3.0\n' > "$vf"
        echo "   已补 kylin-system-version.conf 的 [SYSTEM] 段"
    fi

    # (3) hold 通用内核 (best-effort)。
    chroot "$rootdir" apt-mark hold linux-generic linux-image-generic linux-headers-generic \
        2>/dev/null || true
}

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

    # 3c. 可选：剥掉镜像自带的 Kylin AI 栈（AI 助手/机器人、后端服务、kytensor/
    #     Triton 推理、引擎插件 + 1.3G 模型）。默认关；REMOVE_AI=1 开启。保留桌面
    #     必需的 AI 客户端库，否则 UKUI 桌面会被级联卸载
    #     （见 lib/rootfs-common.sh:remove_kylin_ai）。best-effort，失败不中断。
    if is_true "$REMOVE_AI"; then
        remove_kylin_ai "$ROOTDIR" || echo "WARN: AI 移除步骤返回非零，继续构建" >&2
    fi

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
        "${FIRMWARE_URL:-https://github.com/sonicepro/deepin-sheng-port/releases/download/kernel-bundle-7.2.6/sheng-firmware-master.tar.gz}"
    tar -xzf "$fwdir/fw.tar.gz" -C "$fwdir"
    fwsrc="$(find "$fwdir" -maxdepth 1 -mindepth 1 -type d -name 'sheng-firmware-*' | head -1)"
    [ -n "$fwsrc" ] && cp -a "$fwsrc"/. "$ROOTDIR/lib/firmware/"
    rm -rf "$fwdir"
    echo "    /lib/firmware/qcom:"; ls "$ROOTDIR/lib/firmware/qcom" 2>/dev/null || true

    # 4c. Xiaomi MIPPS 120W charger authentication.
    echo "==> Installing Xiaomi MIPPS auth (120W charging)..."
    _mipps="$(mktemp -d)/mipps.deb"
    if wget -nv -O "$_mipps" "${MIPPS_DEB_URL:-https://github.com/sonicepro/deepin-sheng-port/releases/download/kernel-bundle-7.2.6/xiaomi-mipps-auth.deb}"; then
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
    install_touch_processor "$ROOTDIR"
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

    # 5c. Audio. openKylin's udev coldplug does not autoload the WCD938x codec
    #     core (snd_soc_wcd938x), so the SM8550 sound card ("sound"/snd-sc8280xp)
    #     defers forever ("WCD Playback: codec dai not found") and the system
    #     reports "no soundcards". The overlay ships
    #     /etc/modules-load.d/sheng-audio.conf to load it at boot.
    #     The codec core alone is not enough: if the card driver probes ~10s into
    #     boot (before the ADSP audio subsystem is ready) it fails with -22 and
    #     wedges the ADSP q6APM session, so the card never comes up on that boot
    #     (this is the "audio works on some boots" flakiness). The overlay
    #     blacklists snd_soc_sc8280xp (/etc/modprobe.d/sheng-audio.conf) and
    #     sheng-audio-rebind.service loads it once the ADSP + SoundWire codec are
    #     ready, avoiding the wedging early probe.
    chroot "$ROOTDIR" systemctl enable sheng-audio-rebind.service 2>/dev/null || true

    # 5c-2. Silence the boot/login sounds. They are package files that play on
    #     every login; divert them (so apt upgrades keep the silent versions) and
    #     drop the .silent masters from the overlay in place.
    #       - ukui-login-sound plays ukui-session-manager/startup.wav at login.
    #       - speech-dispatcher's dummy output module (the only module present; the
    #         xunfei/kylin_speech module binaries are missing) otherwise plays a
    #         ~29s English demo (dummy-message.wav) on every login warm-up.
    for _rel in \
        usr/share/ukui/ukui-session-manager/startup.wav \
        usr/share/sounds/speech-dispatcher/dummy-message.wav ; do
        _m="$SCRIPT_DIR/system_files_openkylin/${_rel}.silent"
        if [ -f "$ROOTDIR/$_rel" ] && [ -f "$_m" ]; then
            chroot "$ROOTDIR" dpkg-divert --add --rename \
                --divert "/$_rel.distrib" "/$_rel" 2>/dev/null || true
            cp -a "$_m" "$ROOTDIR/$_rel"
        fi
    done

    # Suspend state: sheng/SM8550's "deep" suspend is unreliable (self-wakes a few
    # seconds in, or fails to resume, so a power-key suspend is hard to wake from).
    # Pin s2idle, which resumes correctly.
    chroot "$ROOTDIR" systemctl enable sheng-mem-sleep.service 2>/dev/null || true

    # Spark Store (Electron/Chromium) 花屏: on this device's mainline graphics
    #     stack (msm + Mesa freedreno + Adreno) Chromium's GPU process crashes,
    #     so the launcher must pass --disable-gpu. Ship the idempotent fixer +
    #     a boot oneshot; the apt post-invoke hook (system_files_openkylin/etc/
    #     apt) also re-applies it after any spark-store (re)install/upgrade.
    chroot "$ROOTDIR" systemctl enable sheng-spark-store-gpu-fix.service 2>/dev/null || true

    # 5d. 如意玲珑 (Linyaps) 运行环境（ll-cli / ll-box；不含商店本体）。见
    #     install_linglong_env 顶部注释。LINGLONG_ENV=0 可跳过。best effort，
    #     失败不中断整个构建。
    if is_true "$LINGLONG_ENV"; then
        install_linglong_env "$ROOTDIR" || echo "WARN: 如意玲珑环境步骤返回非零，继续构建" >&2
    fi

    # 5e. KMRE (麒麟移动运行环境 / Android)。见 install_kmre 顶部注释。
    #     依赖 5b 的覆盖层（apt pins + docker/aapt wrapper 载荷）已就位。
    #     KMRE_ENV=0 可跳过。best effort，失败不中断整个构建。
    if is_true "$KMRE_ENV"; then
        install_kmre "$ROOTDIR" || echo "WARN: KMRE 安装步骤返回非零，继续构建" >&2
    fi

    # 5f. 指纹 (FPC1553 / 电源键指纹)。见 install_fingerprint 顶部注释。
    #     依赖 4（内核 fpc1553 模块已注入，供覆盖 fpc1553.ko）与 5b（覆盖层）之后。
    #     FINGERPRINT_ENV=0 可跳过。best effort，失败不中断整个构建。
    if is_true "$FINGERPRINT_ENV"; then
        install_fingerprint "$ROOTDIR" || echo "WARN: 指纹安装步骤返回非零，继续构建" >&2
    fi

    # 5g. 修 openKylin 系统更新（非 ostree 系统：ostree 钩子 + 版本文件 + 通用内核）。
    #     不修的话真机点“系统更新”会失败或显示异常版本串。best effort。
    fix_system_update "$ROOTDIR" || echo "WARN: 系统更新修复步骤返回非零，继续构建" >&2

    # 6. Users + hostname + locale + timezone.
    setup_users "$ROOTDIR" "$ROOT_PASS" "$USER_NAME" "$USER_PASS" \
        "sudo,audio,video,render,input,plugdev,netdev,network"

    # 6a. 自动转屏（SSC 加速度计 -> openKylin 转屏）。须在 setup_users 之后（要建
    #     用户级服务软链）且 install_touch_processor（步骤 5，落地 ssccli）之后。
    #     见 install_autorotate 顶部注释。AUTOROTATE_ENV=0 可跳过。
    if is_true "$AUTOROTATE_ENV"; then
        install_autorotate "$ROOTDIR" "$USER_NAME" || echo "WARN: 自动转屏步骤返回非零，继续构建" >&2
    fi

    # 6b. Fontconfig: pin the generic families to Noto so linglong/DTK apps don't
    #     render with 华文彩云. openKylin ships 华文彩云 (STCaiyun, a hollow
    #     "outline" font) in the openkylin-fonts package, and keeps the generic
    #     sans-serif/serif/monospace families on Noto via
    #     /etc/fonts/conf.d/64-openkylin-prefer-cjk.conf (openkylin-default-settings).
    #     Apps launched through linglong run against the DEEPIN base's own
    #     fontconfig, which lacks that rule, so their generic families fall back to
    #     华文彩云 and their whole UI renders as hollow outlines (deepin-draw, QQ,
    #     bilibili, ...). A USER-level fontconfig is read by BOTH the host and the
    #     linglong containers (via 50-user.conf + $XDG_CONFIG_HOME), so pin the
    #     generics to Noto here.
    _userfc="$ROOTDIR/home/${USER_NAME}/.config/fontconfig"
    mkdir -p "$_userfc"
    cat > "$_userfc/fonts.conf" <<'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias binding="strong"><family>sans-serif</family><prefer><family>Noto Sans CJK SC</family><family>Noto Sans</family><family>DejaVu Sans</family></prefer></alias>
  <alias binding="strong"><family>Sans Serif</family><prefer><family>Noto Sans CJK SC</family><family>DejaVu Sans</family></prefer></alias>
  <alias binding="strong"><family>Sans</family><prefer><family>Noto Sans CJK SC</family><family>DejaVu Sans</family></prefer></alias>
  <alias binding="strong"><family>serif</family><prefer><family>Noto Serif CJK SC</family><family>Noto Serif</family><family>DejaVu Serif</family></prefer></alias>
  <alias binding="strong"><family>monospace</family><prefer><family>Noto Sans Mono CJK SC</family><family>DejaVu Sans Mono</family></prefer></alias>
</fontconfig>
FONTCONF
    chown -R "${USER_NAME}:${USER_NAME}" "$_userfc"

    # 6c. 亮度持久化：让合成器 gamma-manager 接管屏幕亮度，避免转屏/开机把亮度
    #     重置成最亮。根因：openKylin 的 ukui-settings-daemon 只按"是否存在
    #     /sys/class/backlight/*/brightness 节点"判断硬件背光可调，于是把唯一内屏
    #     当笔记本内屏，每次输出重配置（转屏）都把合成器亮度拉满到 100；而本平板
    #     upm 实际调不了该节点（CanSetBrightness=false）。补丁让
    #     upmSupportAdjustBrightness() 返回 false（等价源码补丁见
    #     docs/patches/ukui-settings-daemon-upmSupportAdjustBrightness.patch）。
    #     BRIGHTNESS_FIX_ENV=0 可跳过。
    if is_true "${BRIGHTNESS_FIX_ENV:-1}"; then
        bash "$SCRIPT_DIR/tools/sheng-usd-brightness-fix.sh" "$ROOTDIR" \
            || echo "WARN: 亮度修复步骤返回非零，继续构建" >&2
    fi

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
