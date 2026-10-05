# deepin-sheng-port 开发维护文档

面向**改构建 / 排查设备问题**的人。只想下载刷机 → 见 [README.md](README.md)。

内容：**构建流程** / **修复清单** / **硬件支持现状** / **已知注意点** / **无线调试**。

## 构建流程

### 目录

```
sheng-deepin-rootfs_build.sh        # Deepin 构建脚本（提取现成 arm64 用户态）
sheng-openkylin-rootfs_build.sh     # openKylin 构建脚本（mmdebstrap/debootstrap 引导）
sheng-openkylin3-rootfs_build.sh    # openKylin 3.0 构建脚本（从官方 arm64 镜像提取用户态）
lib/rootfs-common.sh                # 从上游 vendored 的公共库
system_files/                       # 注入 Deepin 镜像的设备服务/规则脚本
system_files_openkylin/             # openKylin 用的通用设备配置（NM/udev）
.github/workflows/build-deepin.yml  # Deepin 自包含 CI workflow
.github/workflows/build-openkylin.yml # openKylin 自包含 CI workflow
.github/workflows/build-openkylin3.yml # openKylin 3 自包含 CI workflow
```

### 流水线（`sheng-deepin-rootfs_build.sh`）

1. **取源** — 下载 Deepin arm64 用户态（默认官方 community arm64 ISO；也支持 `img.xz`/`tar`/`zip`，按扩展名 + magic 自动识别）
2. **解出用户态** — `unsquashfs`（ISO）/ `tar -x` / **loop 挂载最大 ext4 分区后 `rsync`**（板级镜像）/ `unzip`
3. **定尺寸** — 镜像 = 解压后大小 **+2 GiB**（给 rsync 留余量）
4. **每个启动模式**（`single`/`dual`/`all`）— 建 ext4 镜像 → 挂载 → 灌入用户态
5. **注入** sheng 内核 `.deb`、**固件**、**MIPPS**
6. **设备修复 + 设备服务**（见下「修复清单」；含 `system_files/` 里的脚本/unit + dconf 默认）
7. **用户 / 主机名 / 中文 locale / 时区 / lightdm 自动登录 / fstab**
8. **转 Android sparse `.img` → gzip** → `deepin_<ver>_<mode>_<ts>.img.gz`

### 怎么跑（GitHub Actions）

1. 进本仓库的 **Actions** 页面；
2. 选 **Build Deepin 25 Desktop** → **Run workflow**；
3. 参数：
   - `kernel_version`：默认 `7.1`
   - `kernel_channel`：`stable`（默认）或 `mainline`
   - `boot_mode`：`single`（默认）/ `dual` / `all`
   - `deepin_src_url`：留空用官方 arm64 ISO；或填 deepin-ports 的 flat rootfs / 板级镜像 URL
4. 跑完在 **Artifacts** / **Release** 下载产物（下载与合并见 README）。

### openKylin 流水线（`sheng-openkylin-rootfs_build.sh`）

走的是**上游 debian-sheng / ubuntu-sheng 那套**（openKylin 有 arm64 官方归档，可从仓库引导）：

1. **引导基础系统** — `mmdebstrap`（回退 `debootstrap`；套件名对 debootstrap 是未知的，
   符号链接到通用 Ubuntu 脚本 `gutsy`）从 `http://archive.build.openkylin.top/openkylin/`
   拉取，组件 `main cross pty`，用归档导出的 `openkylin-archive-keyring.gpg` 校验
2. **写 apt 源** — `<suite>` / `<suite>-updates` / `<suite>-security`
3. **桌面元包** — `OPENKYLIN_DESKTOP_META`（默认 `ukui-desktop-environment-core`；完整 `ukui-desktop-environment` 因缺 `libeis1` 装不上；平板 UI 可用 `ukui-tablet-desktop`）**best-effort** 安装
4. **注入** sheng 内核 `.deb` + 固件 + MIPPS；**通用设备修复**（qrtr、触摸校准、WiFi 固件、蓝牙 HID 开机加载、NM 去随机 MAC）
5. **用户 / 主机名 / locale / 时区 / lightdm 自动登录 / fstab**
6. Android sparse → gzip（与 Deepin 产物同构）

参数：`openkylin_suite`（`nile` / `huanghe` / `nile.bedrock` / `yangtze`）、`openkylin_version`
（仅用于命名）、`openkylin_desktop_meta`、`openkylin_mirror`。

> ⚠️ 桌面元包名随 openKylin 版本可能不同，故用 **best-effort**：名字对不上只告警、不中断构建，
> 仍产出可引导（可 SSH）的基础系统；按发行版实际情况覆盖 `OPENKYLIN_DESKTOP_META` 即可。

### openKylin 3.0 流水线 + 如意玲珑 (Linyaps) 运行环境

`sheng-openkylin3-rootfs_build.sh`（CI `build-openkylin3.yml`）与 Deepin 同构 —— **从
openKylin 官方 arm64 镜像提取用户态**（live apt 归档不全，装不出完整 UKUI）。

同一构建循环里有一段 **`install_linglong_env`（步骤 5d）**，负责把**如意玲珑运行环境**
（`ll-cli` / `ll-box`，**不含商店本体**）装好；开关 `LINGLONG_ENV`（默认开，CI 里是
`linglong` 布尔 input）。之所以要专门做，是因为 openKylin 3.0 自带的玲珑 1.5.7 在这台机器上
装了也跑不起来 —— 共 **6 个坑**（都在真机验证过，构建里逐条处理）：

1. **镜像自带 Qt5 是 nile(2.0) 构建**（`5.15.10+dfsg-3ok2.17`）跑在 huanghe 上 → 自带
   ll-cli(1.5.7) 一碰 D-Bus 就段错误 → 升到 huanghe 重建版 `3ok2.18`。
2. 官方 linyaps OBS 的 **`openkylin_3.0`/`openkylin_2.0` 目标只有 amd64**（无 arm64）
   → 装 **arm64 的 `Deepin_25` 目标**（玲珑 1.14；改用 Qt6，镜像 Qt6 6.10.2 正合适）。
3. linyaps 1.14 依赖 **`libyaml-cpp0.7`**，openKylin 只有 0.8 → 从 **Debian** 取 arm64 deb。
4. **`linglong-box` 必须显式升 2.2.1**：`linglong-bin` 依赖写的是 `linglong-box | crun`，
   系统已有 crun 时 apt 就不升 linglong-box → `/usr/bin/ll-box` 仍是 1.5.7、不认 1.14 用的
   `--root`（daemon 日志：`ll-box: unrecognized option '--root'`）→ app 起不来（ll-cli 只笼统
   报 `InitRunContext failed`，**真错在 daemon 侧**，排查看 `journalctl -u
   org.deepin.linglong.PackageManager`）。
5. deepin 的 `linglong-bin` postinst 有个**空 `for …; do / done` 循环**（debhelper 生成时 unit
   列表为空），`/bin/sh`(dash) 语法报错 → 包卡半配置 → 构建里把该循环删掉后再
   `dpkg --configure -a`。
6. 镜像根的 **`/` 与 `/etc` 属主是 uid 1001**（非 root）→ `systemd-tmpfiles` 对所有规则报
   `unsafe path transition` 直接跳过 → `/run/linglong` 被建成 `755 root` 而非 `1777
   deepin-linglong` → `ll-cli run` 报 `failed to create directory: 权限不够`。构建里
   `chown 0:0 / /etc` 归一成 root。

> 装完后 `ll-cli` 可用（`ll-cli search` / `install` / `run` / `list`）。**菜单入口**靠
> `XDG_DATA_DIRS`（由 `/usr/lib/linglong/generate-xdg-data-dirs.sh` 经 `/etc/profile.d/linglong.sh`
> 注入 `/var/lib/linglong/entries/apps/share`），**首次/重新登录**后生效。
> 社区版商店 `flutter-linglong-store` **不在构建内**（用户不需要）；它另需后端
> `storeapi.linyaps.org.cn`，与本环境无关。

### openKylin 3.0：自动转屏（ADSP SSC 加速度计 → UKUI 转屏）

同一构建循环里有 **`install_autorotate`（步骤 6a；开关 `AUTOROTATE_ENV`，默认开）**，让平板
**自动转屏**开箱即用。链条与根因（真机逐一验证）：

- **UKUI 转屏能力** = 会话 D-Bus `com.kylin.statusmanager.interface.set_rotation(orientation, who, why)`
  （`kylin-status-manager`）。取值 **`normal` / `left` / `right` / `upside-down`** —— 即 0°横 / 竖 / 竖 / 180°（“上下颠倒”）。
- **传感器 = ADSP SSC 加速度计**（`icm4x6xx`），走 **libssc（QMI over QRTR）**。之前 QRTR 上没有
  SSC service（`0x190` = 400）、`ssccli` 报 `SSC QMI Service not found`。**根因是缺
  `protection-domain-mapper`**：ADSP 的传感器 PD（`sensorspd`）要等 AP 侧 servreg 就绪（`pd-mapper`）
  再被 `adsprpcd` 拉起，才会注册该 service —— 只装 pd-mapper 或只跑 adsprpcd 都不行，且要**清启动
  （reboot）** 后才生效。构建里：装 `protection-domain-mapper`（+`qrtr-tools`/`rmtfs`）并 enable
  `pd-mapper`；把镜像自带的 `/usr/bin/adsprpcd`（**0644 → `ExecStart` 203/EXEC**）`chmod 0755`；
  enable `adsprpcd-sensorspd` 并挂到 `multi-user.target`。
- **不能用 openKylin 自带自动转屏**：它走 Qt5 Sensors → `iio-sensor-proxy` → libssc。本机固件的
  加速度计属性里**没有 `measurement_id`**（mount-matrix 也全 0），`iio-sensor-proxy` 3.8 在
  `src/drv-ssc-accel.c:121` 断言失败 → **core dump** → `isSupportedAutoRotation()` 恒 `false`。
  故改用自带的 **`sheng-autorotate`** 守护进程：跑 `ssccli --sensor accelerometer` 读 X/Y/Z →
  `atan2(gy,gx)` → `normal/left/right/upside-down` → `dbus-send` 调 `set_rotation`（0.6s 防抖、
  平放不转、dbus 失败重试、ssccli 挂了自动重启）。**以 `luser` 跑**（session bus 只认 uid 1000；
  root 连不上用户 session bus）。
- **权限**：`/dev/fastrpc-adsp` 是 `0600 root:root` → 覆盖层 `70-sheng-fastrpc.rules` 把
  `fastrpc-*` 改 `0660 group=luser`，`luser` 才能跑 `ssccli`。
- 落地文件：`system_files_openkylin/usr/local/bin/sheng-autorotate`、
  `system_files_openkylin/etc/systemd/user/sheng-autorotate.service`（enable 软链由构建为用户建）、
  `system_files_openkylin/etc/udev/rules.d/70-sheng-fastrpc.rules`。

> 轴映射（真机标定）：屏法线 = 传感器 **Z**；正常横屏时 in-plane 重力 = **+X** →
> `+X→normal`、`+Y→left`、`-X→upside-down`、`-Y→right`。

### 只构建 boot 镜像（轻量，不重建 rootfs）

只想要/重做 `boot_sheng_*.img`（比如已有 rootfs）时，跑 **Build boot images** workflow
（`build-bootimg.yml`）：纯 Python `mkbootimg`，跑在 `ubuntu-latest`（**不需要 arm runner**），
1~2 分钟，只下载内核 `.deb` 现场生成两个 boot 镜像。

## 修复清单

| 问题 | 修法 |
|---|---|
| Deepin 社区源**没有 arm64**（只有 amd64/i386）→ 无法 debootstrap | 取**预构建 arm64 用户态** → 摊平成 ext4 |
| **官方 ISO 根只解出第一个 squashfs**（`filesystem.squashfs`）→ 少 ~8 GiB、缺壁纸/应用 | 按 `/LIVE/filesystem.module` 解**全部** `filesystem*.squashfs`（主 + extra 叠加） |
| **live 根 `/var/lib/dpkg` 为空** → apt/dpkg 全废、`openssh-server` 装不上、`accounts-daemon` 失败 | 用 ISO 里的 `filesystem.packages` 清单**重建 `/var/lib/dpkg/status`** |
| **live 根没有 apt 列表** → `apt-get install` 报“没有可用的软件包” | 写死 Deepin 源 + 装包前 `apt-get update` |
| **`deepin-face` / `deepin-immutable-cleanup` 失败**（无面容硬件 / ISO 的 ostree 不可变部署，我们是普通 ext4） | `systemctl mask` 掉 |
| **所有 linglong 应用（QQ/bilibili…）起不来**（`failed to create directory` / `build cfg error`） | ISO 根把 `/` `/etc` `/usr` 等 **309 个文件属主设成了 uid 1001**（非 root）→ `systemd-tmpfiles` 拒跑（`unsafe path transition`）→ `/run/linglong` 没建出来；构建里 `chown` 回 **root** |
| **openKylin3：玲珑 app 打不开**（`InitRunContext failed` / `ll-box: unrecognized option '--root'`） | `linglong-box` 没跟着 `linglong-bin` 升（`linglong-box | crun` 被已有 crun 满足）→ `/usr/bin/ll-box` 还是 1.5.7；构建显式装 `linglong-box` 2.2.1（详见「如意玲珑运行环境」） |
| **openKylin3：玲珑 app 装不上 / 权限错**（`failed to create directory: 权限不够`） | 同 uid-1001 病根：`/` `/etc` 属主是 1001 → `systemd-tmpfiles` 跳过 → `/run/linglong` 是 `755 root` 而非 `1777`；构建 `chown 0:0 / /etc` |
| **openKylin3：`ll-cli` 一碰 D-Bus 就段错误** | 镜像自带 Qt5 是 nile 构建；构建 `apt-get install --only-upgrade libqt5{core,dbus,gui,network,widgets}5` 升到 huanghe 重建版 |
| **缺 GPU 固件**（`a740_sqe.fw`/`gmu_gen70200.bin`）→ **黑屏** | 固件 `.deb` 的 blob 从 `/usr/lib/` **搬到 `/lib/firmware/`**，再叠加完整固件仓库 |
| **WiFi（ath12k WCN7850）** 起不来 | `fix_wifi_firmware`：`board-2.bin` → `board.bin` 伪装 |
| **openKylin3：自动转屏不工作**（`ssccli` 报 `SSC QMI Service not found`；屏幕不跟随旋转） | 缺 `protection-domain-mapper`：装并 enable `pd-mapper` + `chmod 0755 /usr/bin/adsprpcd` + enable `adsprpcd-sensorspd`（挂 multi-user.target），并用 `sheng-autorotate` 直连 `ssccli` 调 `set_rotation`；见「openKylin 3.0：自动转屏」 |
| **`qrtr-ns.service` 失败** | 装 `qrtr` 包 + `ConditionPathExists` 兜底（没有就跳过） |
| **`getty@ttyMSM0` 失败** | 去掉（内核命令行 `con_enabled=0`，该串口不存在） |
| **没声音**（WirePlumber 走 ACP 不走 UCM → Dummy 输出） | 打补丁 `use-acp=false` + `sheng-audio-rebind`（ADSP 竞态后重探）+ `sheng-audio-ucm`（应用 UCM + 开 6 个 cs35l43 功放） |
| **重启后没声音**（WirePlumber 早于声卡启动 → 只出 `null-sink`、默认输出指向它） | 注释 `module-always-sink` + 登录自启 `sheng-default-sink`：真实 sink 缺失时**自动重启 PipeWire** 并钉住默认输出 |
| **蓝牙鼠标连不上**（配对成功，但没输入设备、光标不动） | `uhid`/`hidp`（蓝牙 HID 传输）是内核模块且无人自动加载 → `/etc/modules-load.d/` **开机加载** |
| **WiFi 每次重启都要重输密码** | ISO 里带着**制作者的 WiFi 连接**（含其 PSK，既泄漏又误导）→ 首次开机 NM 先试它（密码错）失败 → 用户重输又堆出多份同名连接；构建里**删掉 ISO 预置的 NM 连接** |
| **登录页 UI 特别小**（不跟随桌面缩放 250%） | greeter 的 DConfig 里没有缩放项 → fallback 100%；`system_files` 改成**读用户 `~/.config/deepin/qt-theme.ini` 的 `ScreenScaleFactors`**（构建 `chmod 711 /home/<user>` 让登录器读得到） |
| **登出提示音特别大**（不跟随用户音量） | 提示音由 `sound-theme-player` **直接走 ALSA**、绕过 PipeWire 音量；`dde-session` 又不看 `enable-event-sounds` → 构建把 `desktop-logout.wav`/`desktop-login.wav` **换成静音 wav**（`system_files/usr/share/sounds/deepin/stereo/`） |
| **文件管理器“计算机”里一堆小磁盘** | `system_files/etc/udev/rules.d/70-hide-small-partitions.rules`：给 sda1–27 / `sd[b-z]` 等 **<1 GiB** 分区设 `UDISKS_IGNORE=1` → udisks2（及文件管理器）不再列出 |
| **DDE 系统更新下载不了**（暂缓） | DDE「系统更新」的**下载步骤只会走** `deepin-immutable-ctl upgrade --download-only`（ostree 不可变系统专用），本机是摊平 ext4、无 `/sysroot/ostree/repo`、无 ostree 远端 → 必然失败；删 ctl 二进制只会把它变成 `fork/exec … no such file`。**保留** ISO 的 `/etc/deepin-immutable-ctl` 与 `/usr/sbin/deepin-immutable-ctl`（与官方一致）；要真正可用需把端口改造成 ostree 部署，待后续 |
| **120W 快充不生效** | 装 `xiaomi-mipps-auth`（内核 `pmic-glink` 节点已在） |
| **待机秒醒 / 屏幕自动亮**（插充电时尤甚） | sheng（SM8550）的 `deep` 挂起会在几秒内自唤醒（充电时几乎必现）→ `system_files` 加 `sheng-mem-sleep.service`：开机把默认睡眠态钉成 **`s2idle`**，`deep` 不再启用 |
| **刷完分区没撑满** | fstab 加 `x-systemd.growfs`（首启自动扩容） |
| **要做单次解压**（GitHub zip + 7z 双层） | 直接输出 sparse `.img`，Release 走 `.img.gz` 分卷 |
| **屏幕键盘难用 / 皮肤·尺寸不对** | dconf 系统默认（`system_files/etc/dconf/db/local.d/00-sheng-onboard`）：onboard 停靠底部 + **Blackboard 皮肤 / Small 布局** + 自动弹出；`window-handles=''` 防多指滑动误改大小。**两个前提缺一不可**：(1) 必须 `dconf update` 编译（需 `dconf-cli`，构建里装）——否则 `/etc/dconf/db/local` 根本不生成、默认静默失效（gsettings 一直报 `unable to open /etc/dconf/db/local`）；(2) `use-system-defaults=true`——onboard 该键（schema 默认 true，含义“先从系统默认读配置、首启后自动重置”）设成 false 就永不读系统默认、转而用 onboard 自带默认，皮肤尺寸全不对 |
| **屏幕键盘没有关闭键**（且有个没用的“清除/删除”键） | 构建给 `Small.onboard` 打补丁：行末的 `id="DELE"` 键（图标 `erase.svg`，方框带 ×）**就地**改成 onboard 内建 Hide（`id="hide" svg_id="DELE"` → `close.svg`，点一下收起键盘）；真·Delete 保留在 Fn 层的文字 “Del” 键上 |
| **屏幕键盘想手动改大小** | `window-handles=''` 关掉所有拖拽手柄（含 `M`）→ **多指拖动不再引出 resize 抓手**、不会误改大小（onboard 只要 `window-handles` 含 `M`，一次多指拖动就会 `on_drag_gesture_begin` → `show_touch_handles()` 引出抓手）。改大小改由回车长按弹窗的 **move** 键触发：构建把 `Small.onboard` 的 `RTRN_popup`“关闭键盘”键换成 `move`（`id="move" svg_id="hide.popup"`），**并给 onboard 的 `BCMove.update` 打补丁去掉对 `M` 手柄的依赖** → 该键在 `window-handles=''` 下仍可见/可用，点它呼出抓手改大小 |
| **登录页键盘皮肤和桌面不一致** | greeter 以 `lightdm` 用户运行，只读**系统 dconf 默认**（`system-db:local`），看不到用户 dconf。系统默认写了 `theme='Blackboard'`、`layout='Small'`（与桌面一致）→ 登录页统一。前提：`dconf-cli` + `dconf update` |
| **屏幕键盘变成白色皮肤**（官方没有，自己调的） | 当前主题是 `Blackboard`，其配色方案 `Charcoal` 被改成白色（底 `#ffffff`、字 `#1a1a1a`）；`Granite`/`White` 配色与 `White.theme` 也一并改成白。这几个文件随构建覆盖镜像：`system_files/usr/share/onboard/themes/{Charcoal,Granite,White}.colors` + `White.theme` |
| **三指上滑呼出键盘** | `system_files/usr/local/sbin/sheng-gesture-keyboard.py`（读触摸屏 MT-B 事件识别三指上滑，调 onboard D-Bus `org.onboard.Onboard.Keyboard.Show()`）+ `system_files/etc/systemd/system/sheng-gesture-keyboard.service`（`User=luser`）。构建把 `luser` 加进 `input` 组并 `systemctl enable` 该服务。⚠️ 该 unit **不能写 `After=graphical.target`**：它与 `WantedBy=multi-user.target` 组成 ordering cycle（graphical.target 本身 after multi-user.target）→ systemd 删掉 start 任务 → 服务永远 `inactive (dead)`、三指无反应（实测设备名 `NVTCapacitiveTouchScreen` 与 D-Bus 路径 `/org/onboard/Onboard/Keyboard` 都正确） |
| **登录页不显示（黑屏）** | 注入的 greeter 脚本 `system_files/etc/deepin/greeters.d/lightdm-deepin-greeter` 在 git 里是 `100644`（非可执行），构建 `cp -a` 原样拷入 → lightdm 起 greeter session 执行失败 → 登录页不出。构建的 `chmod 0755 …/usr/local/sbin/*.sh` 匹配不到它 → 构建里对它单独 `chmod 0755` |
| **登录页/桌面屏幕键盘起不来（缺 a11y 总线）** | onboard 启动要连 AT-SPI 无障碍总线，连不上**直接退出**。该总线由 `at-spi2-core` 提供（`/usr/libexec/at-spi-bus-launcher`）；基础镜像没装它（`dpkg: un`）→ onboard 起不来。构建 `apt-get install -y at-spi2-core`（与 `dconf-cli` 一起装） |
| **WiFi 每次开机不自动连、堆重复连接** | NM 激活 WiFi 时随机化 MAC（`ip link` 显示本地管理地址），保存的连接被绑到当时那个随机 MAC（connection 里 `802-11-wireless.mac-address=<random>`）→ 重启后接口 MAC 变了 → 连接匹配不上、不自动连；重连又生成一条绑新 MAC 的同名连接。构建加 `system_files/etc/NetworkManager/conf.d/00-sheng-wifi.conf`：`wifi.scan-rand-mac-address=no` + `wifi.cloned-mac-address=permanent` 固定用硬件 MAC |
| **Electron/Chromium 应用点输入框不弹键盘** | onboard 自动弹出**只认 AT-SPI**；Chromium 系默认不建无障碍树 → VSCode、QQ、Chrome 等不弹（GTK/Qt 正常）。按应用强开 a11y：VSCode `"editor.accessibilitySupport":"on"`，其它 `--force-renderer-accessibility` |
| **卸载应用时输密码的弹窗不能拖动**（X11 下 `dde-polkit-agent` 给 AuthDialog 设了 `Qt::BypassWindowManagerHint` → override-redirect，绕过窗口管理器 → 系统拖窗失效） | `tools/dde-polkit-movable/interposer.c`：编一个**只剥掉这一个 flag** 的 `LD_PRELOAD` 拦截器 → `system_files/etc/systemd/user/dde-polkit-agent.service.d/zz-movable.conf` 注入，构建时装到 `/usr/local/lib/dde-sheng-movable/libpolkitmove.so`。弹窗变回 WM 管理的可拖动窗口（不影响 Popup/ToolTip） |
| **电量一直显示“充电中”**（实际在用电池）；**没插电源却仍用“使用电源”的息屏/待机时间** | 两症状同源：dde-daemon 的（系统总线）`OnBattery` 只认 `type=="mains"` 的 power_supply（`dde-api/powersupply.IsMains`），sheng 内核只暴露 `USB`/`Wireless` 线供（qcom-battmgr-usb/wls、ucsi-source-psy）→ 找不到 mains → `OnBattery` 恒 `false`。于是面板显示充电，且**会话侧** `dde-session-daemon`（`session/power1` 的 `PowerSavePlan`，决定 AC/电池两套息屏/待机延时）读到 false → 一直套用“使用电源”的延时。`tools/dde-power-ac/interposer.c`：`LD_PRELOAD` 把 `qcom-battmgr-usb` 报成 `mains`、其 `online` 取真实电池充电态 → `system_files/etc/systemd/system/dde-system-daemon.service.d/zz-power-ac.conf` 注入，构建装到 `/usr/local/lib/dde-sheng-power/`。会话侧读系统 `OnBattery`，无需另改 |
| DNS/下载/挂载各种小坑 | chroot DNS、保留 URL 扩展名 + magic 嗅探、`mkdir` 挂载点、选最大 ext4、去掉 `--info=progress2` |

## 硬件支持现状

内核/固件全部来自同一套 sheng mainline（全注入，**驱动层已同步**）；下列差异都是
**mainline 上游对个别外设支持不全**，非本镜像缺驱动。

| 硬件 | 状态 |
|---|---|
| 触摸 / WiFi / 蓝牙 | ✅ |
| 音频（含开机自愈） | ✅ |
| 120W 充电（MIPPS 认证） | ✅ |
| GPU / 显示 | ✅ |
| **传感器**（加速度计/陀螺/光感/霍尔） | 🟡 挂在 ADSP **SSC** 后面，走 `libssc`（QMI over QRTR）。**加速度计已可用并用于 openKylin3 自动转屏**（见「openKylin 3.0：自动转屏」）；需装 `protection-domain-mapper` + enable `adsprpcd`。`iio-sensor-proxy` 3.8 对本机固件仍会 core dump（缺 `measurement_id`），故用 `sheng-autorotate` 直连 `ssccli`；陀螺/磁力/光/距也能 `ssccli` 读到（未接桌面） |
| **相机** | ⚠️ 驱动/媒体图/传感器绑定都在，`libcamera` 也能识别并**抓原始帧**；但彩色卡在 libcamera 的 debayer **不支持该传感器 10-bit（R10_CSI2P）格式**。DDE 相机应用是 linglong 应用、假设高通私有栈，mainline 上多半用不了 |
| **触控笔**（小米焦点笔） | ❌ 内核只有**充电/配对**侧（`pen_*` @ pmic-glink），**无书写输入**（触摸数字转换器不报笔，私有协议未解码） |

### 已知问题（未解决）

| 问题 | 现状 |
|---|---|
| **登录界面白框** | DDE greeter 拿不到 Application Manager/主题（非原厂硬件的老毛病）；已开 autologin，不影响进桌面 |
| **maliit 屏幕键盘** | Wayland 优先，X11 下窗口显示不了；X11 只能用 onboard |
| **相机 / 触控笔** | 见上「硬件支持现状」——mainline 上游限制（传感器/加速度计已可用，见「openKylin 3.0：自动转屏」） |

## 已知注意点

- **磁盘**：完整 Deepin 桌面 rootfs 约 10–20 GiB（官方 ISO 的完整根约 20 GiB），镜像按解压后大小自动定尺寸。
  workflow 里已加“释放磁盘空间”步骤；`dual` 模式会构建两个镜像、占用更大，
  建议优先 `single`。
- **源**：默认用 **官方 community arm64 ISO**（飞腾/鲲鹏取向）。可用 `deepin_src_url` 覆盖成其它镜像（脚本自动识别 ISO/tar/img.xz/zip）。
- **无 initramfs**：本方案复用的 `boot_sheng_*.img` **不带 ramdisk**，依赖内核内置
  UFS/ext4。
- **DDE 会话**：脚本 best-effort 配了 lightdm 自动登录；若 Deepin 25 用的不是
  lightdm，该文件无害。
- **首次启动**：fstab 已带 `x-systemd.growfs`，开机**自动**把根撑满分区（无需手动）。根分区是 `PARTLABEL=linux`（如 `/dev/sda31`，**不是** `sda30`）；只有旧镜像才需手动 `sudo resize2fs <根设备>`。

## 无线调试（ssh over WiFi / USB 网络）

镜像内置 USB RNDIS/ECM 网卡 gadget + sshd，**无需接屏幕**即可调试。

默认账号 `luser/luser`、root `1234`（`luser` 可 sudo）。

### WiFi（真正无线）

平板连上 WiFi 后，同一局域网内直接 SSH：

- 平板 WiFi IP **每次重启都会变**，先用网段扫描找它：
  ```bash
  nmap -p 22 192.168.5.0/24     # 换成你所在的网段
  ```
  （开发时用的扫描/命令脚本 `scan_ssh.py` / `ssh.py` 在开发环境里，未随仓库发布。）
- 连上后看启动问题：
  ```bash
  ssh luser@<ip>
  systemctl --failed
  journalctl -xb
  ```
