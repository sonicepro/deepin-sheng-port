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
#       AUTOBRIGHTNESS_ENV=0 (optional — skip the auto-brightness setup: the
#                       sheng-autobrightness daemon, SSC ambient light -> UKUI
#                       screen brightness); default: on
#       BRIGHTNESS_FIX_ENV=0 (optional — skip the ukui-settings-daemon brightness
#                       patches: upmSupportAdjustBrightness()->false and the
#                       composer software-brightness neutraliser); default: on
#       SHENG_COMPOSITOR_BRIGHTNESS (optional — the constant the compositor
#                       software brightness is pinned to; 100 == no dim);
#                       default: 100
#       PANEL_BRIGHTNESS_ENV=0 (optional — skip the panel-backlight engine: the
#                       sheng-panel-brightness daemon that maps the UKUI
#                       brightness value onto /sys/class/backlight); default: on
#       BRIGHTNESS_BRIDGE_ENV=0 (optional — skip the control-center "Display"
#                       brightness-slider bridge: mirror the gsettings key
#                       org.ukui.power-manager brightness-ac to the working
#                       setPrimaryBrightness path); default: on
#       SUSPEND_BACKLIGHT_ENV=0 (optional — skip cutting the panel backlight at
#                       suspend (logind PrepareForSleep), so the backlight no
#                       longer stays lit during the inhibitor wait); default: on
#       INHIBIT_FIX_ENV=0 (optional — skip cutting logind's InhibitDelayMaxSec to
#                       1s (kylin-process-manager's ~5s sleep delay lock delays
#                       the actual suspend, so the screen is dark but the power
#                       key looks dead)); default: on
#       POWER_BLANK_ENV=0 (optional — skip adding the "关闭显示器" option to the
#                       control center "按下电源键时执行" dropdown and making the
#                       power key blank/unblank the panel when it is selected);
#                       default: on
#       DISPLAY_SCALE_ENV=0 (optional — skip adding 250%/275% entries to the
#                       control center "Display" screen-zoom dropdown; the panel
#                       is 3048px wide, below the hardcoded 3072/3840 gates, so
#                       the list otherwise stops at 225%); default: on
#       PEONY_IDM_FIX_ENV (optional — mask the peony "Intelligent Space" IDM
#                       service (com.peony.idm.service) so the FIRST file-manager
#                       open doesn't freeze ~10s ("peony not responding") waiting
#                       on it. The service only stalls like that when the kylin-ai
#                       backend is absent, so the default FOLLOWS REMOVE_AI: on
#                       when AI is stripped (REMOVE_AI=1), off when AI is kept
#                       (智能空间 then works). Set =1/=0 to override.
#       GESTURE_SCROLL_FIX_ENV=0 (optional — skip the ukui touch-gesture fix.
#                       ukui's libqt5-gesture-extensions grabs each scroll-area
#                       viewport with QScroller::TouchGesture, which makes Qt stop
#                       synthesizing mouse from touch, so peony (opens on mouse
#                       double-click) can't open folders by finger in a scrollable
#                       view. The fix switches it to LeftMouseButtonGesture (touch
#                       is synthesized to mouse again -> double-click works, and the
#                       scroller now drives mouse-drag flick -> one-finger scroll
#                       kept); default: on
#       OSK_TAP_ENV=0 (optional — skip the on-screen-keyboard change: stop
#                       kylin-virtual-keyboard from popping when an app focuses a
#                       text field (an LD_PRELOAD gate on fcitx5), and instead open
#                       it on a DOUBLE-tap of the screen — but only while a text
#                       field is focused, so a double-tap on (say) a file-manager
#                       folder does nothing.  See install_osk_tap for the fcitx5
#                       start-order trap that made this non-deterministic across
#                       reboots); default: on
#       FP_UNLOCK_WAKE_ENV=0 (optional — skip the fingerprint "unlock lights the
#                       panel" daemon: while the panel is DPMS-off and the lock
#                       screen holds the fingerprint armed, a successful match
#                       unlocks the session but the panel stays dark (a finger
#                       touch is not an input event, so kylin-wlcom does not
#                       unblank). The daemon watches org.ukui.ScreenSaver's
#                       `unlock` signal (plus a GetLockState poll) and runs
#                       kscreen-doctor -d on; mismatches leave the screen dark);
#                       default: on
#       AUTOLOGIN_ENV=0 (optional — DISABLE lightdm auto-login: boot stops at
#                       the ukui-greeter and asks for the password, but the
#                       desktop session then loads only AFTER it (a visible wait).
#                       ON by default: lightdm auto-logs-in the desktop user AND
#                       sheng-lock-on-login immediately locks the session, so the
#                       desktop preloads during boot BEHIND the lock screen and the
#                       user still types a password (fast login)); default: on
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

# --- openKylin / lightdm autologin + lock-on-login (UKUI uses lightdm) -------
# ON by default (AUTOLOGIN_ENV=1): lightdm auto-logs-in the desktop user, and
# sheng-lock-on-login locks the session the moment it comes up -- so the desktop
# preloads during boot BEHIND the lock screen (no wait after the password) while
# the user still types a password (at the lock screen, not the greeter).  Set
# AUTOLOGIN_ENV=0 for a plain ukui-greeter (asks for the password at boot, but
# the session then loads only after it -> a visible wait).
# This is the BOOT login only -- independent of the in-session "what the power
# key / blank does" and "唤醒屏幕时需要密码" behaviour, which is
# org.ukui.screensaver close-activation-enabled (see sheng-screen-toggle).
AUTOLOGIN_ENV="${AUTOLOGIN_ENV:-1}"

setup_lightdm_autologin() {
    local rootdir="$1" user="$2"
    mkdir -p "$rootdir/etc/lightdm/lightdm.conf.d"
    cat > "$rootdir/etc/lightdm/lightdm.conf.d/00-sheng-autologin.conf" <<EOF
[Seat:*]
autologin-user=${user}
autologin-user-timeout=0
EOF
}

# Lock the session right after (auto)login so the desktop can preload behind the
# lock screen.  lightdm 1.32.0-ok11's own autologin-user-lock /
# enable-autologin-user-lock keys have NO effect (verified on device), so we lock
# ourselves via an XDG autostart entry in the UKUI "Initialization" phase (same
# phase as ukui-screensaver, so the lock covers the desktop rather than appearing
# after it).  Only installed alongside autologin.
install_lock_on_login() {
    local rootdir="$1"
    echo "==> 配置开机自动登录后立即锁屏 (sheng-lock-on-login)..."
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-lock-on-login" \
        "$rootdir/usr/local/bin/sheng-lock-on-login"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/xdg/autostart/sheng-lock-on-login.desktop" \
        "$rootdir/etc/xdg/autostart/sheng-lock-on-login.desktop"
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
#   6) 容器镜像虽然声明了 32 位（odm 的 abilist32 / ro.zygote=zygote64_32），但起来
#      后 product 级 ro.product.cpu.abilist32 是空值 → 纯 64 位，32 位包装不上。
#      用 kmre-abi32（用户级服务）通过 manager 的 D-Bus setSystemProp 设回去。
#   7) 软件商店「移动应用」页一直转圈：商店调扩展插件 getAndroidApplist 的参数值
#      不被接受（只有 ("arm64","","","") 可用）→ kydroid_app_list 恒 0 行；而商店
#      进程读的是预处理副本 uksc_pre.db（重建时丢掉该表）。用 kmre-applist-bridge
#      （用户级服务）直接取目录并同时写两个库。
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
        kmre-zram.service dnsmasq kmre-abi32.service \
        2>/dev/null || true
    rm -f "$rootdir/usr/sbin/policy-rc.d"

    # 7) 让容器支持 32 位（armeabi-v7a）应用。上游镜像是双 ABI（odm 里
    #    ro.odm.product.cpu.abilist32=armeabi-v7a,armeabi、ro.zygote=zygote64_32），
    #    但容器起来后 product 级 ro.product.cpu.abilist32 是**空值**，把 32 位屏蔽掉
    #    → 商店/容器按纯 64 位对待，目录里少数 32 位包装不上。用 kmre manager 的
    #    D-Bus setSystemProp 设回去（该接口不接受空字符串，故只能开不能关；重复设置
    #    幂等）。运行期执行，故用用户级服务（刷机后随桌面会话起来）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/sbin/kmre-abi32.sh" \
        "$rootdir/usr/local/sbin/kmre-abi32.sh"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/user/kmre-abi32.service" \
        "$rootdir/etc/systemd/user/kmre-abi32.service"

    # 8) 软件商店「移动应用」列表修复。商店请求扩展插件的 getAndroidApplist 时，
    #    插件只在参数为 ("arm64","","","") 时返回数据；商店传的
    #    ("arm64","UNKNOWN","3.0","12") 被 Qt 以 UnknownMethod 拒掉 → 目录写不进
    #    kydroid_app_list（恒 0 行）→ 页面永远停在「获取移动应用列表」。且商店进程
    #    读的是预处理副本 ~/.cache/uksc/uksc_pre.db（预处理重建时会丢掉该表）。
    #    故用用户级服务直接取目录并写入两个库（只写该表与 dict 的更新时间键）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/kmre-applist-bridge" \
        "$rootdir/usr/local/bin/kmre-applist-bridge"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/user/kmre-applist-bridge.service" \
        "$rootdir/etc/systemd/user/kmre-applist-bridge.service"

    # 用户级服务的 enable 软链（构建期没有用户 session，systemctl --user enable
    # 不可用；与 install_autorotate 等保持同一做法）。
    local _udir="$rootdir/home/${USER_NAME}/.config/systemd/user" _t _u
    mkdir -p "$_udir"
    for _u in kmre-abi32.service kmre-applist-bridge.service; do
        for _t in default.target graphical-session.target; do
            mkdir -p "$_udir/${_t}.wants"
            ln -sf "/etc/systemd/user/${_u}" "$_udir/${_t}.wants/${_u}"
        done
    done
    chown -R "${USER_NAME}:${USER_NAME}" "$rootdir/home/${USER_NAME}/.config" 2>/dev/null || true

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

# --- 自动亮度 (auto-brightness: ADSP SSC 环境光 -> UKUI 亮度) --------------------
# 目标：刷机后自动亮度开箱即用。链条与根因（真机逐一验证）：
#   1) 光感 = ADSP SSC stk3bcx，走 libssc（`ssccli --sensor light` 输出
#      "Light sensor measurement: N Lux"）。依赖 install_touch_processor（落地
#      libssc/ssccli）与 install_autorotate（pd-mapper + adsprpcd-sensorspd 把
#      传感器 PD 带起来，SSC 才注册 QMI service）——须在其后调用。
#   2) 亮度 = 会话 D-Bus org.ukui.SettingsDaemon /GlobalBrightness 的
#      org.ukui.SettingsDaemon.Brightness.setPrimaryBrightness(u)（与手动亮度
#      滑块同一条路，走合成器 gamma）。
#   3) 开关 = 控制中心「显示」页写的 gsettings 键
#      org.ukui.SettingsDaemon.plugins.auto-brightness auto-brightness。
#   4) 不用系统自带的 auto-brightness 插件：libauto-brightness.so 能读光感，但其
#      adjustBrightnessWithLux 通过内部 BrightThread 施加亮度，在本机
#      Wayland/kylin-wlcom 上无效（真机实测：开灯/关灯、连它自带的 debug-lux 扫值
#      亮度都不变）。故改用本仓库自带的 sheng-autobrightness 守护进程。
#   5) 用户偏置：曲线是固定映射，会把用户手调的亮度覆盖掉（「自动亮度又变暗」）。
#      守护进程轮询 getPrimaryBrightness，把不是自己写出的变化记为偏置
#      bias = manual - curve(lux)，此后 applied = clamp(curve(lux)+bias,1,100)。
#      偏置持久化在用户目录 ~/.config/sheng/autobrightness.conf，是**运行时状态**，
#      构建不需要任何额外步骤；回归测试见 tools/test-sheng-autobrightness-bias.py。
#   AUTOBRIGHTNESS_ENV=0 可跳过。
AUTOBRIGHTNESS_ENV="${AUTOBRIGHTNESS_ENV:-1}"

install_autobrightness() {
    local rootdir="$1" uname="$2"
    echo "==> 配置自动亮度 (SSC 环境光 -> openKylin 亮度)..."

    # (1) 落地守护进程 + 用户级服务（显式安装保证权限位；overlay 的 cp -a 已拷贝过）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-autobrightness" \
        "$rootdir/usr/local/bin/sheng-autobrightness"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/user/sheng-autobrightness.service" \
        "$rootdir/etc/systemd/user/sheng-autobrightness.service"

    # (2) 建用户级 enable 软链（构建期没有用户 session，systemctl --user enable 用不了）。
    local udir="$rootdir/home/${uname}/.config/systemd/user"
    local target
    for target in default.target graphical-session.target; do
        mkdir -p "$udir/${target}.wants"
        ln -sf "/etc/systemd/user/sheng-autobrightness.service" \
            "$udir/${target}.wants/sheng-autobrightness.service"
    done
    chown -R "${uname}:${uname}" "$rootdir/home/${uname}/.config" 2>/dev/null || true

    echo "   自动亮度配置完成"
}

# --- 「设置→显示器→亮度」滑块桥接 (brightness-ac -> setPrimaryBrightness) --------
# 目标：控制中心「设置→显示器」的亮度滑块开箱即用。真机根因（见 DEVELOPMENT.md）：
#   ukui-control-center 的 libdisplay.so 由其 Widget::isSetGammaBrightness() 决定走
#   gamma 路(setPrimaryBrightness) 还是硬件路(brightness-ac)。本机恒为 false
#   （upm 在但 CanSetBrightness=false、产品名非 VAH510/"all in one"、无
#   gammaforbrightness 键）→ 只写 gsettings org.ukui.power-manager brightness-ac，
#   指望 upm 走硬件背光；而本机 upm 驱动不了 ktz8866（RegulateBrightness 返回
#   "no effective node"）→ 拖动无效。侧栏/快捷中心直接走 setPrimaryBrightness
#   （gamma）所以正常。做法：用户级守护桥接——brightness-ac 变化 → 转发到
#   org.ukui.SettingsDaemon /GlobalBrightness setPrimaryBrightness(u)（滑块能真正改亮度）。
#   注意：**反向**（当前亮度 → 回写 brightness-ac）自 2026-10 起默认关闭
#   （SHENG_BRIDGE_MIRROR=1 才开）。原因（真机 dbus-monitor + dconf 负载解码实证）：
#   brightness-ac 是 ukui-settings-daemon 的**输入键**，回写它会给 usd 的转屏故障
#   "上膛"——之后一次输出重配置就把亮度放大到很亮/100%（观测 51→78、59→92→100）。
#   详见 DEVELOPMENT.md「转屏时亮度被顶到 100%」。
#   BRIGHTNESS_BRIDGE_ENV=0 可跳过。
BRIGHTNESS_BRIDGE_ENV="${BRIGHTNESS_BRIDGE_ENV:-1}"

install_brightness_bridge() {
    local rootdir="$1" uname="$2"
    echo "==> 配置「设置→显示器」亮度滑块桥接..."

    # (1) 落地守护进程 + 用户级服务（显式安装保证权限位）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-brightness-ac-bridge" \
        "$rootdir/usr/local/bin/sheng-brightness-ac-bridge"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/user/sheng-brightness-ac-bridge.service" \
        "$rootdir/etc/systemd/user/sheng-brightness-ac-bridge.service"

    # (2) 建用户级 enable 软链（构建期没有用户 session，systemctl --user enable 用不了）。
    local udir="$rootdir/home/${uname}/.config/systemd/user"
    local target
    for target in default.target graphical-session.target; do
        mkdir -p "$udir/${target}.wants"
        ln -sf "/etc/systemd/user/sheng-brightness-ac-bridge.service" \
            "$udir/${target}.wants/sheng-brightness-ac-bridge.service"
    done
    chown -R "${uname}:${uname}" "$rootdir/home/${uname}/.config" 2>/dev/null || true

    echo "   显示器亮度滑块桥接配置完成"
}

# --- 面板背光引擎 (UKUI 亮度值 -> 真实面板背光) ---------------------------------
# 目标：亮度由真实背光承担，彻底干掉合成器「软件亮度滤镜」（对像素相乘，压暗部、
#   暗场景发灰）。真机验证过的链路：
#   1) 所有亮度 UI —— 快捷操作/侧栏滑块、控制中心「设置→显示器」滑块（经本仓库
#      sheng-brightness-ac-bridge）、自动亮度（sheng-autobrightness）——都收敛到
#      ukui-settings-daemon 的 org.ukui.SettingsDaemon.Brightness.setPrimaryBrightness(u)，
#      它把用户值(0..100)持久化到 /etc/ukui/usd/globalconf.ini 的 [color] <output>=<v>。
#      真机实测：该 config 值是忠实的用户值，且与合成器亮度**解耦**（把合成器钉到
#      任意值都不影响它）→ 稳定的控制通道。
#   2) 合成器软件亮度由步骤 6c 的补丁钉在 100（== 不减光）→ 无滤镜。
#   3) 本守护进程 sheng-panel-brightness 读该 config 值 → 线性映射后写入
#      /sys/class/backlight/ktz8866-backlight/brightness。三条 UI 路径因此一起驱动背光。
#   须在 setup_users 之后（要建用户级服务软链）。PANEL_BRIGHTNESS_ENV=0 可跳过。
PANEL_BRIGHTNESS_ENV="${PANEL_BRIGHTNESS_ENV:-1}"

install_panel_brightness() {
    local rootdir="$1" uname="$2"
    echo "==> 配置面板背光引擎 (UKUI 亮度 -> 真实背光)..."

    # (1) 落地守护进程 + 用户级服务（显式安装保证权限位）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-panel-brightness" \
        "$rootdir/usr/local/bin/sheng-panel-brightness"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/user/sheng-panel-brightness.service" \
        "$rootdir/etc/systemd/user/sheng-panel-brightness.service"

    # (2) 建用户级 enable 软链（构建期没有用户 session，systemctl --user enable 用不了）。
    local udir="$rootdir/home/${uname}/.config/systemd/user"
    local target
    for target in default.target graphical-session.target; do
        mkdir -p "$udir/${target}.wants"
        ln -sf "/etc/systemd/user/sheng-panel-brightness.service" \
            "$udir/${target}.wants/sheng-panel-brightness.service"
    done
    chown -R "${uname}:${uname}" "$rootdir/home/${uname}/.config" 2>/dev/null || true

    echo "   面板背光引擎配置完成"
}

# --- peony 首次打开卡 10s + "无响应"（停用 IDM/AI 服务）-------------------------
# 症状：开机后**首次**点桌面「计算机」打开文件管理(peony) 卡 ~10s，随后合成器弹
#   「peony程序无响应（进程号XXX）是否强制关闭应用」。冷启动 10.6s、二次起 0.4s。
# 根因：peony 首启会 D-Bus 激活 com.peony.idm.service → 用户 unit
#   peony-intelligent-data-management-service.service（"智能空间/AI 分组"）；该服务连
#   本机**不存在**的 Kylin AI socket /tmp/.kylin-ai-business-unix/1000/
#   KnowledgeBaseService.sock，每秒重试、**10s 后放弃**（kb_session_init 失败）；peony
#   同步等该服务就绪 → 主线程冻结 10s → wlcom 在 ~10s 处记 "peony view is not
#   responding"。真机实测：pkill 掉该服务后重启 peony 又卡 10s，服务在跑则 0.2s。
# 该服务只在 kylin-ai 后端缺失时才会每秒重试 10s（连不上 /tmp/.kylin-ai-business-unix/…
#   KnowledgeBaseService.sock）；后端在时智能空间正常。故**只在 AI 被剥离时**掩码该用户
# 服务：D-Bus 激活立即失败 → peony 不再等待（真机首开 10.4s→0.2s）；保留 AI 时不掩码，
# 智能空间可正常用。默认跟随 REMOVE_AI（可显式设 PEONY_IDM_FIX_ENV 覆盖）。
# 须在 setup_users 之后（写 ~/.config/systemd/user 掩码软链）。
if is_true "$REMOVE_AI"; then
    PEONY_IDM_FIX_ENV="${PEONY_IDM_FIX_ENV:-1}"   # AI 已剥离 → 掩码，防止首开白卡 10s
else
    PEONY_IDM_FIX_ENV="${PEONY_IDM_FIX_ENV:-0}"   # 保留 AI → 不掩码，智能空间正常用
fi

install_peony_idm_fix() {
    local rootdir="$1" uname="$2"
    echo "==> 停用 peony「智能空间」IDM 服务（修首次打开文件管理卡 10s + 无响应）..."

    # 掩码：软链指向 /dev/null（等价 `systemctl --user mask`）。构建期没有用户 session，
    #   systemctl --user 用不了，直接建软链即可（systemd 开机读同一路径）。
    local udir="$rootdir/home/${uname}/.config/systemd/user"
    mkdir -p "$udir"
    ln -sf /dev/null "$udir/peony-intelligent-data-management-service.service"
    chown -R "${uname}:${uname}" "$rootdir/home/${uname}/.config" 2>/dev/null || true

    echo "   peony IDM 服务已掩码 (~/.config/systemd/user/…->/dev/null)"
}

# --- ukui 触摸手势：让可滚动目录里"手指点按能打开文件夹"且保留一指滚动 -----------
# UKUI 手势插件 libqt5-gesture-extensions 对滚动区 viewport 调
#   QScroller::grabGesture(viewport, TouchGesture) → 给 viewport 设 WA_AcceptTouchEvents
#   → Qt 不再把触摸合成鼠标 → peony(靠鼠标双击打开)在可滚动目录里手指点不开（放得下
#   不滚动的目录仍正常；鼠标不受影响）。修法：把手势类型改成 LeftMouseButtonGesture
#   （触摸仍合成鼠标→双击成立；QScroller 改抓鼠标拖拽→一指滚动保留）。就地打 .so 字节补丁。
# 见 tools/sheng-gesture-scroll-fix.sh。GESTURE_SCROLL_FIX_ENV=0 可跳过。
GESTURE_SCROLL_FIX_ENV="${GESTURE_SCROLL_FIX_ENV:-1}"

install_gesture_scroll_fix() {
    local rootdir="$1"
    echo "==> 修补 ukui 触摸手势（修可滚动目录里手指点不开文件夹 + 保留一指滚动）..."
    bash "$SCRIPT_DIR/tools/sheng-gesture-scroll-fix.sh" "$rootdir"
}

# --- 「设置→显示器→缩放屏幕」加 250% / 275% 档 --------------------------------
# 目标：控制中心「设置→显示器」的缩放下拉框能选 250% 与 275%。openKylin 3.0 的
#   ukui-control-center libdisplay.so 里 OutputConfig::initScaleItem() 用**硬编码
#   分辨率阈值**决定放哪些档：
#     宽度 > 2560 → 225%   宽度 > 3072 → 250%   宽度 > 3840 → 275%
#   本机面板原生 3048×2032（3048 大于 2560 但小于 3072/3840）→ 下拉框最大只到
#   225%。做法：把 250%/275% 的闸门 cmp #0xc00(3072) / cmp #0xf00(3840) 都改成
#   #0xa00(2560)，与 225% 同级。合成器(wlcom)本身支持 2.5/2.75 分数缩放。同长度
#   二进制替换、无源码改动，稳定。libdisplay.so 里两种闸门各 3 处（多个
#   OutputConfig 变体），全替换。DISPLAY_SCALE_ENV=0 可跳过。
DISPLAY_SCALE_ENV="${DISPLAY_SCALE_ENV:-1}"

install_display_scale() {
    local rootdir="$1"
    echo "==> 给「设置→显示器→缩放屏幕」加 250%/275% 档..."

    local so
    for so in "$rootdir"/usr/lib/*/ukui-control-center/libdisplay.so; do
        [ -f "$so" ] || continue
        python3 - "$so" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
NEW = struct.pack("<I", 0x7128001f)            # cmp w0, #0xa00 (2560) — 与 225% 同级
GATES = {
    struct.pack("<I", 0x7130001f): "250% (cmp #0xc00, 3072)",
    struct.pack("<I", 0x713c001f): "275% (cmp #0xf00, 3840)",
}
total = 0
for old, name in GATES.items():
    n, i = 0, 0
    while True:
        j = d.find(old, i)
        if j < 0:
            break
        d[j:j+4] = NEW
        n += 1
        i = j + 4
    if n == 0 and d.find(NEW) < 0:
        print("   WARN: 未找到 %s 闸门，跳过（版本可能已变）" % name)
    total += n
    print("   %s: 改 %d 处" % (name, n))
open(p, "wb").write(d)
print("   共把 %d 处缩放闸门阈值下调到 2560" % total)
PY
    done
    echo "   缩放屏幕 250%/275% 档配置完成"
}

# --- 休眠时立即关背光 (logind PrepareForSleep -> backlight off) ---------------
# 目标：消除点休眠后"黑屏但背光还亮一段时间"的空档。根因（真机定位）：logind 收到
#   休眠请求先发 PrepareForSleep(true)，合成器立即关输出（画面黑）但不动背光；背光
#   要等内核真正 suspend 才由 DSI 面板/ktz8866 驱动切断，而 logind 之前要等一批
#   delay inhibitor（Screen Locker/进程管理器/QQ…）放行——这段时间就是"背光还亮"。
#   系统里没有任何 sleep hook 写 /sys/class/backlight。做法：系统级守护监听
#   PrepareForSleep，收到 true 立刻把背光写到 0，收到 false（恢复/取消）还原。
#   SUSPEND_BACKLIGHT_ENV=0 可跳过。
SUSPEND_BACKLIGHT_ENV="${SUSPEND_BACKLIGHT_ENV:-1}"

install_suspend_backlight() {
    local rootdir="$1"
    echo "==> 配置休眠即时关背光 (PrepareForSleep -> backlight off)..."

    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/sbin/sheng-suspend-backlight" \
        "$rootdir/usr/local/sbin/sheng-suspend-backlight"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/system/sheng-suspend-backlight.service" \
        "$rootdir/etc/systemd/system/sheng-suspend-backlight.service"
    chroot "$rootdir" systemctl enable sheng-suspend-backlight.service 2>/dev/null \
        || echo "WARN: enable sheng-suspend-backlight 失败" >&2

    echo "   休眠即时关背光配置完成"
}

# --- 缩短挂起等待 (logind InhibitDelayMaxSec) --------------------------------
# 目标：把"屏幕灭 → 真正睡"之间 ~5 秒的窗口压到 1 秒。根因：kylin-process-manager
#   挂着一个 "sleep" delay 锁不放（实测放到超时才放），logind 会硬等满
#   InhibitDelayMaxSec（默认 5s）才强制挂起；这段时间屏幕已黑、系统还没睡，按电源
#   键无效。装一个 logind drop-in 把它设为 1s。INHIBIT_FIX_ENV=0 可跳过。
#   （suspend→resume 本身仍有 s2idle 往返开销，这里只去掉可避免的"挂起前等待"。）
INHIBIT_FIX_ENV="${INHIBIT_FIX_ENV:-1}"

install_logind_inhibit() {
    local rootdir="$1"
    echo "==> 缩短挂起等待 (logind InhibitDelayMaxSec=1)..."
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/logind.conf.d/10-sheng-inhibit.conf" \
        "$rootdir/etc/systemd/logind.conf.d/10-sheng-inhibit.conf"
    echo "   logind 挂起等待已设为 1s（开机生效）"
}

# --- 屏幕键盘：只在「双击输入框」时弹（停用一聚焦就自动弹）+ 弹出提速 ----------
# 目标：openKylin 的屏幕键盘（kylin-virtual-keyboard，由 fcitx5 驱动）本来会「一聚焦
#   输入框就自动弹」——界面打开自动聚焦、微信切好友时都会弹。改成：**只有双击、且
#   当前有输入框聚焦时**才弹 —— 点好友/按钮、滚动、双击文件夹都不弹。
# 做法：
#   ① fcitx5 侧：LD_PRELOAD 垫片 sheng-osk-gate.so（源码 tools/sheng-osk-gate.c，
#      **预编译 arm64**）。它拦掉自动弹出 `UserInterfaceManager::showVirtualKeyboard()`，
#      并用 show/hide 请求维护「当前是否有输入框聚焦」标记：文本框获得焦点→show→
#      $XDG_RUNTIME_DIR/sheng-osk-textactive=1；失去焦点→hide→0。
#   ② 守护 sheng-osk-tap.py：只读触摸屏（MT-B，不抢事件）识别**双击**；双击时若标记=1
#      且键盘没显示 → 调 fcitx5 后端 `ShowVirtualKeyboard` 弹出。
#   ③ 自启：由包装脚本 fcitx5-sheng 拉起 fcitx5（带 LD_PRELOAD）；新增
#      sheng-osk-tap.desktop 经包装脚本 sheng-osk-tap-run 拉起守护。
#
# 本步骤**只做「双击输入框弹出键盘」这一件事**。曾试验并已全部撤销（原因见
# DEVELOPMENT.md「屏幕键盘弹出偏慢 / 转屏后屏幕键盘尺寸不自适应」）：
#   - gsettings preload-view-enabled=true（展开快约 38%，但窗口尺寸冻结）
#   - sheng-osk-rotate 转屏守护（转屏时重启键盘以重建几何）
#   - docs/patches/kylin-virtual-keyboard-preload-rotation.patch（上游一行补丁）
#
# ⚠️ 启动顺序陷阱（真机踩过，两处入口必须都带垫片，否则垫片会「有时在、有时不在」）：
#   fcitx5 有两条启动路径，而 `org.fcitx.Fcitx5` 这个总线名只能被一方抢到，输的一方
#   直接退出（日志里表现为 `Unable to request dbus name. Is there another fcitx
#   already running?`）：
#     1) /etc/xdg/autostart/fcitx5.desktop → systemd app-fcitx5@autostart.service
#     2) /usr/share/dbus-1/services/org.fcitx.Fcitx5.service → D-Bus 按需激活
#        （登录时 kylin-virtual-keyboard 会先来要这个名字，所以**常常是这条赢**）
#   原先只有 (1) 带 LD_PRELOAD，于是 (2) 赢的那些开机里 fcitx5 是**裸启动**的：
#   垫片没进 → 没人写 sheng-osk-textactive → 守护每次双击都正确识别后又
#   「skip (no text field focused)」→ 键盘根本弹不出来。因为取决于谁先跑，
#   表现为**偶发**；又因为守护 stderr 原先丢进 /dev/null，现象完全不可观测。
#   修法：两条入口都 exec 同一个包装脚本 fcitx5-sheng（内含 LD_PRELOAD），
#   并把守护 stderr 落到 /tmp/osk-tap/tap.log（sheng-osk-tap-run）。
#   OSK_TAP_ENV=0 可跳过（默认开）。
install_osk_tap() {
    local rootdir="$1"
    echo "==> 屏幕键盘：停用自动弹出，改成「双击输入框」弹出 + 预加载提速..."

    # ① 垫片与双击守护
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/usr/local/lib/sheng-osk-gate.so" \
        "$rootdir/usr/local/lib/sheng-osk-gate.so"
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-osk-tap.py" \
        "$rootdir/usr/local/bin/sheng-osk-tap.py"

    # ② fcitx5 两条启动入口共用的包装脚本（内含 LD_PRELOAD，缺一不可）
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/fcitx5-sheng" \
        "$rootdir/usr/local/bin/fcitx5-sheng"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/usr/share/dbus-1/services/org.fcitx.Fcitx5.service" \
        "$rootdir/usr/share/dbus-1/services/org.fcitx.Fcitx5.service"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/xdg/autostart/fcitx5.desktop" \
        "$rootdir/etc/xdg/autostart/fcitx5.desktop"

    # ③ 双击守护包装脚本（把 stderr 落到日志，否则双击为何不弹不可观测）
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-osk-tap-run" \
        "$rootdir/usr/local/bin/sheng-osk-tap-run"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/xdg/autostart/sheng-osk-tap.desktop" \
        "$rootdir/etc/xdg/autostart/sheng-osk-tap.desktop"

    # 至此只保留「双击输入框弹出键盘」这一项功能。
    #
    # 曾经还装过（已按决定移除，理由见 DEVELOPMENT.md 对应条目）：
    #   - 键盘视图预加载 preload-view-enabled=true（展开快约 38%，但窗口尺寸会冻结）
    #   - 转屏守护 sheng-osk-rotate（转屏时重启键盘以重建几何）
    # 两者互相依存且引入的问题多于收益；用户要求回到"只有双击唤醒键盘"的原始状态。
    # 相关文件（system_files_openkylin/usr/local/bin/sheng-osk-rotate、
    # etc/systemd/user/sheng-osk-rotate.service、usr/share/glib-2.0/schemas/
    # 99-sheng-osk.gschema.override、docs/patches/kylin-virtual-keyboard-
    # preload-rotation.patch）已不再被本函数安装，应从仓库删除。

    echo "   已装：sheng-osk-gate.so(LD_PRELOAD) + fcitx5-sheng(两条入口) + 双击守护及日志包装 + 两个自启项"
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
#   3) 自研补丁（预编译二进制在 fingerprint_payload/）：
#      - libfprint-2.so.2.0.0（同一颗 so 上两处改动）：
#        a. 改 fpc1553 驱动 wait_for_finger_lift，验证/识别匹配到即上报（不再等抬手）
#           但保留芯片 deep-sleep → **按住即解锁**。
#        b. 关掉 libfprint 的**温度模型**（等价源码 `dev_class->temp_hot_seconds = -1`；
#           上游所有 match-on-chip 驱动都显式关它，本移植漏了 → 落回默认 180 秒）。
#           不关的后果：息屏期间锁屏对话框每 30 秒重挂识别 → 180 秒判 HOT → 框架报
#           “Device disabled to prevent overheating.” → 此后每次识别**瞬时失败**，
#           被锁屏对话框当连续失败并立即重试 → 几秒烧完 MaxFailedTimes=5，
#           亮屏即见「指纹失败，5 次机会全用完」。补丁脚本 tools/sheng-fp-thermal-off.sh（仅改 2 字节）。
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

    # (4) 私有 libfprint（按住即解锁 + 关闭温度模型）——覆盖 deb 里的同名文件。
    if [ -f "$SCRIPT_DIR/fingerprint_payload/libfprint-2.so.2.0.0" ]; then
        install -Dm755 "$SCRIPT_DIR/fingerprint_payload/libfprint-2.so.2.0.0" \
            "$rootdir/usr/lib/xiaomi-sheng-fingerprint/libfprint-2.so.2.0.0"
        echo "   私有 libfprint 覆盖为『按住即解锁 + 关温度模型』版"
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

# --- 息屏指纹解锁自动亮屏（手机式） ------------------------------------------
# 目标：**息屏**（面板 DPMS Off）时用指纹解锁后，屏幕**自动点亮**并进桌面，不用再按
#   一次电源键 —— 与手机一致。指纹不匹配时保持黑屏。
# 为什么需要它：sheng-idle-lock / sheng-screen-toggle 会在息屏时先锁屏再关屏，锁屏
#   对话框整段时间都武装着指纹；匹配成功时**对话框自己会解锁会话**，但面板仍是
#   DPMS Off，用户看不到任何反馈。而指纹触摸**不是输入事件**，kylin-wlcom 不会因此
#   唤醒面板（触摸/电源键才会），所以必须主动点屏。
# 做法：用户级守护进程 sheng-fp-unlock-wake 监听会话总线 org.ukui.ScreenSaver 的
#   `unlock` 信号（并用 GetLockState 每秒轮询兜底）；发现「会话已解锁 + 内屏黑着」
#   （dpms==off 或 bl_power!=0）→ `kscreen-doctor -d on`。
# 须在 setup_users 之后（要建用户级服务软链）。FP_UNLOCK_WAKE_ENV=0 可跳过。
FP_UNLOCK_WAKE_ENV="${FP_UNLOCK_WAKE_ENV:-1}"

install_fp_unlock_wake() {
    local rootdir="$1" uname="$2"
    echo "==> 配置息屏指纹解锁自动亮屏 (sheng-fp-unlock-wake)..."

    # (1) 落地守护进程 + 用户级服务（显式安装保证权限位）。
    install -Dm755 "$SCRIPT_DIR/system_files_openkylin/usr/local/bin/sheng-fp-unlock-wake" \
        "$rootdir/usr/local/bin/sheng-fp-unlock-wake"
    install -Dm644 "$SCRIPT_DIR/system_files_openkylin/etc/systemd/user/sheng-fp-unlock-wake.service" \
        "$rootdir/etc/systemd/user/sheng-fp-unlock-wake.service"

    # (2) 建用户级 enable 软链（构建期没有用户 session，systemctl --user enable 用不了）。
    local udir="$rootdir/home/${uname}/.config/systemd/user"
    local target
    for target in default.target graphical-session.target; do
        mkdir -p "$udir/${target}.wants"
        ln -sf "/etc/systemd/user/sheng-fp-unlock-wake.service" \
            "$udir/${target}.wants/sheng-fp-unlock-wake.service"
    done
    chown -R "${uname}:${uname}" "$rootdir/home/${uname}/.config" 2>/dev/null || true

    echo "   息屏指纹解锁自动亮屏已配置"
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

    # 6a-2. 自动亮度（SSC 环境光 -> openKylin 亮度）。与自动转屏同源（共用 pd-mapper
    #       + adsprpcd-sensorspd 把传感器 PD 带起来），须在 install_autorotate 之后、
    #       setup_users 之后。见 install_autobrightness 顶部注释。AUTOBRIGHTNESS_ENV=0 可跳过。
    if is_true "$AUTOBRIGHTNESS_ENV"; then
        install_autobrightness "$ROOTDIR" "$USER_NAME" || echo "WARN: 自动亮度步骤返回非零，继续构建" >&2
    fi

    # 6a-3. 「设置→显示器」亮度滑块桥接（brightness-ac <-> setPrimaryBrightness，双向）。
    #       须在 setup_users 之后（要建用户级服务软链）。见 install_brightness_bridge
    #       顶部注释。BRIGHTNESS_BRIDGE_ENV=0 可跳过。
    if is_true "$BRIGHTNESS_BRIDGE_ENV"; then
        install_brightness_bridge "$ROOTDIR" "$USER_NAME" || echo "WARN: 亮度滑块桥接步骤返回非零，继续构建" >&2
    fi

    # 6a-4. 「设置→显示器→缩放屏幕」加 250%/275% 档（libdisplay.so 硬编码闸门
    #       3072/3840 -> 2560，本机面板 3048 宽否则只到 225%）。见 install_display_scale
    #       顶部注释。DISPLAY_SCALE_ENV=0 可跳过。
    if is_true "$DISPLAY_SCALE_ENV"; then
        install_display_scale "$ROOTDIR" || echo "WARN: 缩放屏幕 250% 步骤返回非零，继续构建" >&2
    fi

    # 6a-5. 面板背光引擎（UKUI 亮度值 -> 真实面板背光；配合 6c 把合成器软件亮度钉在
    #       100 干掉滤镜）。须在 setup_users 之后（要建用户级服务软链）。
    #       见 install_panel_brightness 顶部注释。PANEL_BRIGHTNESS_ENV=0 可跳过。
    if is_true "$PANEL_BRIGHTNESS_ENV"; then
        install_panel_brightness "$ROOTDIR" "$USER_NAME" || echo "WARN: 面板背光引擎步骤返回非零，继续构建" >&2
    fi

    # 6a-6. 停用 peony「智能空间」IDM 服务（首次打开文件管理卡 10s + "无响应"）：
    #       peony 首启同步等该服务连入缺失的 kylin-ai 后端 10s。须在 setup_users
    #       之后（写 ~/.config/systemd/user 掩码软链）。见 install_peony_idm_fix
    #       顶部注释。PEONY_IDM_FIX_ENV=0 可跳过。
    if is_true "$PEONY_IDM_FIX_ENV"; then
        install_peony_idm_fix "$ROOTDIR" "$USER_NAME" || echo "WARN: peony IDM 停用步骤返回非零，继续构建" >&2
    fi

    # 6a-7. ukui 触摸手势修补（可滚动目录里手指点不开文件夹 + 保留一指滚动）。
    #       见 install_gesture_scroll_fix / tools/sheng-gesture-scroll-fix.sh 顶部注释。
    #       GESTURE_SCROLL_FIX_ENV=0 可跳过。
    if is_true "$GESTURE_SCROLL_FIX_ENV"; then
        install_gesture_scroll_fix "$ROOTDIR" || echo "WARN: ukui 手势修补步骤返回非零，继续构建" >&2
    fi

    # 6a-8. 屏幕键盘「双击输入框弹出」+ 弹出预加载提速。见 install_osk_tap
    #       顶部注释（含 fcitx5 两条启动入口的竞态陷阱）。OSK_TAP_ENV=0 可跳过。
    if is_true "${OSK_TAP_ENV:-1}"; then
        install_osk_tap "$ROOTDIR" || echo "WARN: 屏幕键盘双击步骤返回非零，继续构建" >&2
    fi

    # 6a-9. 息屏指纹解锁自动亮屏（手机式：息屏时指纹一碰 → 解锁并自动点亮屏幕）。
    #       见 install_fp_unlock_wake 顶部注释。FP_UNLOCK_WAKE_ENV=0 可跳过。
    if is_true "${FP_UNLOCK_WAKE_ENV:-1}"; then
        install_fp_unlock_wake "$ROOTDIR" "$USER_NAME" || echo "WARN: 息屏指纹亮屏步骤返回非零，继续构建" >&2
    fi

    # 6a-10. 设备节点权限兜底：镜像里的 /dev/null 可能是 0755（应为 0666）。普通用户
    #        写 /dev/null 会直接失败，从而让 `cmd >/dev/null 2>&1` 这类重定向**整条命令
    #        被静默跳过**（本仓库多个 sheng-* 脚本都用这种写法）。这里纠正为 0666。
    if [ -e "$ROOTDIR/dev/null" ]; then
        chmod 0666 "$ROOTDIR/dev/null" 2>/dev/null || true
        echo "==> /dev/null 权限纠正为 0666"
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

    # 6c. 亮度（两处，同一组件 ukui-settings-daemon）：
    #     ① 让合成器 gamma-manager 接管屏幕亮度，避免转屏/开机把亮度重置成最亮。
    #        根因：它只按“是否存在 /sys/class/backlight/*/brightness 节点”判断硬件背光可调，
    #        于是把唯一内屏当笔记本内屏，每次输出重配置（转屏）都把合成器亮度拉满 100；
    #        而本平板 upm 实际调不了该节点（CanSetBrightness=false）。→ 让
    #        upmSupportAdjustBrightness() 返回 false。
    #     ② 中性化合成器「软件亮度滤镜」：把 GmHelper 的 用户→合成器 映射
    #        (normalize/denormalizeBrightness) 钉成常量 100（== 不减光）。合成器的软件
    #        亮度是对像素相乘的滤镜，会压暗部（暗场景发灰）；现在亮度改由真实背光承担
    #        （见 6a-5 的 sheng-panel-brightness 引擎）。滑块值仍由 daemon 持久化到
    #        globalconf.ini 的 [color]（真机实测与合成器解耦），故钉 100 不影响用户值。
    #     二进制补丁（等价源码补丁见 docs/patches/）；BRIGHTNESS_FIX_ENV=0 可跳过。
    #     SHENG_COMPOSITOR_BRIGHTNESS 可改（默认 100）。
    if is_true "${BRIGHTNESS_FIX_ENV:-1}"; then
        SHENG_COMPOSITOR_BRIGHTNESS="${SHENG_COMPOSITOR_BRIGHTNESS:-100}" \
            bash "$SCRIPT_DIR/tools/sheng-usd-brightness-fix.sh" "$ROOTDIR" \
            || echo "WARN: 亮度修复步骤返回非零，继续构建" >&2
    fi

    # 6d. （已废弃）不再把硬件背光钉死在固定值。现在面板背光本身由 sheng-panel-brightness
    #     引擎按 UI 亮度值驱动（见 6a-5），合成器软件亮度被 6c 钉在 100。旧的固定背光
    #     sheng-backlight-fixed.service 会与引擎抢背光，故不再安装/启用。

    # 6e. 休眠时立即关背光（PrepareForSleep -> backlight off），消除"黑屏但背光
    #     还亮"的空档。见 install_suspend_backlight 顶部注释。SUSPEND_BACKLIGHT_ENV=0 可跳过。
    if is_true "$SUSPEND_BACKLIGHT_ENV"; then
        install_suspend_backlight "$ROOTDIR" || echo "WARN: 休眠关背光步骤返回非零，继续构建" >&2
    fi

    # 6f. 缩短挂起等待窗口（logind InhibitDelayMaxSec=1s，原来默认 5s），让电源键
    #     更快可用。见 install_logind_inhibit 顶部注释。INHIBIT_FIX_ENV=0 可跳过。
    if is_true "$INHIBIT_FIX_ENV"; then
        install_logind_inhibit "$ROOTDIR" || echo "WARN: logind 挂起等待步骤返回非零，继续构建" >&2
    fi

    # 6g. 电源键"关闭显示器"：给控制中心「设置→电源→按下电源键时执行」下拉加「关闭显示器」
    #     项（libpower.so），并让 ukui-settings-daemon 的 media-keys 处理 power 键时，
    #     当 button-power=blank 就切换面板背光（libmedia-keys.so + sheng-pwrkey 包装脚本 +
    #     sheng-screen-toggle）。见 tools/sheng-power-button-blank-fix.sh 顶部注释。
    #     POWER_BLANK_ENV=0 可跳过。
    if is_true "${POWER_BLANK_ENV:-1}"; then
        bash "$SCRIPT_DIR/tools/sheng-power-button-blank-fix.sh" "$ROOTDIR" \
            || echo "WARN: 电源键关闭显示器步骤返回非零，继续构建" >&2
        chmod 0755 "$ROOTDIR/usr/bin/sheng-pwrkey" \
                   "$ROOTDIR/usr/local/bin/sheng-screen-toggle" \
                   "$ROOTDIR/usr/local/bin/sheng-idle-lock" 2>/dev/null || true
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
    #    Autologin is ON by default (AUTOLOGIN_ENV=1), paired with
    #    sheng-lock-on-login so the desktop preloads behind the lock screen;
    #    AUTOLOGIN_ENV=0 leaves the plain ukui-greeter.
    if is_true "${AUTOLOGIN_ENV:-1}"; then
        setup_lightdm_autologin "$ROOTDIR" "$USER_NAME" \
            || echo "WARN: autologin 步骤返回非零，继续构建" >&2
        install_lock_on_login "$ROOTDIR" \
            || echo "WARN: lock-on-login 步骤返回非零，继续构建" >&2
    fi
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
