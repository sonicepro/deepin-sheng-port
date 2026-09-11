# deepin-sheng-port

把 **Deepin 25（crimson）arm64** 用户态，配上小米平板 6S Pro（`sheng`，SM8550）的
sheng 内核/固件，做成可 `fastboot` 刷入的镜像。**全部在 GitHub Actions 云端构建**，
本地只用 `fastboot` 刷机。

本仓库**自包含**：不依赖上游 code002 仓库里的 workflow；内核 `.deb` 直接从上游
Release 下载。

## 为什么是"提取现成 rootfs"而不是 debootstrap

- Deepin 官方社区源 `cdn-community-packages.deepin.com/deepin/dists/apricot/Release`
  的 `Architectures:` **只有 `amd64 i386`**，没有 arm64。→ 无法对 Deepin 仓库
  `debootstrap --arch=arm64`。
- Deepin arm64 只通过 **deepin-ports** 以**预构建镜像**发布（deepin 25 代号
  **crimson**）：官方 arm64 ISO、板级 `.img.xz`、`FlatBuild_*.zip`。

所以本仓库：**取现成 arm64 用户态 → 摊平成 ext4 → 注入 sheng 内核 .deb + 设备修复
→ 打成可刷 rootfs**。

## 目录

```
sheng-deepin-rootfs_build.sh        # 构建脚本
lib/rootfs-common.sh                # 从上游 vendored 的公共库
.github/workflows/build-deepin.yml  # 自包含 CI workflow
```

## 构建脚本做了什么 / 修复了哪些问题

### 流水线（`sheng-deepin-rootfs_build.sh`）

1. **取源** — 下载 Deepin arm64 用户态（默认官方 community arm64 ISO；也支持 `img.xz`/`tar`/`zip`，按扩展名 + magic 自动识别）
2. **解出用户态** — `unsquashfs`（ISO）/ `tar -x` / **loop 挂载最大 ext4 分区后 `rsync`**（板级镜像）/ `unzip`
3. **定尺寸** — 镜像 = 解压后大小 **+2 GiB**（给 rsync 留余量）
4. **每个启动模式**（`single`/`dual`/`all`）— 建 ext4 镜像 → 挂载 → 灌入用户态
5. **注入** sheng 内核 `.deb`、**固件**、**MIPPS**
6. **设备修复 + 设备服务**（见下表；含 `system_files/` 里的脚本/unit + dconf 默认）
7. **用户 / 主机名 / 中文 locale / 时区 / lightdm 自动登录 / fstab**
8. **转 Android sparse `.img` → gzip** → `deepin_<ver>_<mode>_<ts>.img.gz`

### 修复清单

| 问题 | 修法 |
|---|---|
| Deepin 社区源**没有 arm64**（只有 amd64/i386）→ 无法 debootstrap | 取**预构建 arm64 用户态** → 摊平成 ext4 |
| **官方 ISO 根只解出第一个 squashfs**（`filesystem.squashfs`）→ 少 ~8 GiB、缺壁纸/应用 | 按 `/LIVE/filesystem.module` 解**全部** `filesystem*.squashfs`（主 + extra 叠加） |
| **live 根 `/var/lib/dpkg` 为空** → apt/dpkg 全废、`openssh-server` 装不上、`accounts-daemon` 失败 | 用 ISO 里的 `filesystem.packages` 清单**重建 `/var/lib/dpkg/status`** |
| **live 根没有 apt 列表** → `apt-get install` 报“没有可用的软件包” | 写死 Deepin 源 + 装包前 `apt-get update` |
| **`deepin-face` / `deepin-immutable-cleanup` 失败**（无面容硬件 / ISO 的 ostree 不可变部署，我们是普通 ext4） | `systemctl mask` 掉 |
| **缺 GPU 固件**（`a740_sqe.fw`/`gmu_gen70200.bin`）→ **黑屏** | 固件 `.deb` 的 blob 从 `/usr/lib/` **搬到 `/lib/firmware/`**，再叠加完整固件仓库 |
| **WiFi（ath12k WCN7850）** 起不来 | `fix_wifi_firmware`：`board-2.bin` → `board.bin` 伪装 |
| **`qrtr-ns.service` 失败** | 装 `qrtr` 包 + `ConditionPathExists` 兜底（没有就跳过） |
| **`getty@ttyMSM0` 失败** | 去掉（内核命令行 `con_enabled=0`，该串口不存在） |
| **`usb-gadget-net` 失败**（`203/EXEC`） | `ExecStart=/bin/bash …` + 无 UDC 时 `ConditionPathExistsGlob` 跳过 |
| **没声音**（WirePlumber 走 ACP 不走 UCM → Dummy 输出） | 打补丁 `use-acp=false` + `sheng-audio-rebind`（ADSP 竞态后重探）+ `sheng-audio-ucm`（应用 UCM + 开 6 个 cs35l43 功放） |
| **重启后没声音**（WirePlumber 早于声卡启动 → 只出 `null-sink`、默认输出指向它） | 注释 `module-always-sink` + 登录自启 `sheng-default-sink`：真实 sink 缺失时**自动重启 PipeWire** 并钉住默认输出 |
| **蓝牙鼠标连不上**（配对成功，但没输入设备、光标不动） | `uhid`/`hidp`（蓝牙 HID 传输）是内核模块且无人自动加载 → `/etc/modules-load.d/` **开机加载** |
| **120W 快充不生效** | 装 `xiaomi-mipps-auth`（内核 `pmic-glink` 节点已在） |
| **刷完分区没撑满** | fstab 加 `x-systemd.growfs`（首启自动扩容） |
| **要做单次解压**（GitHub zip + 7z 双层） | 直接输出 sparse `.img`，Release 走 `.img.gz` 分卷 |
| **屏幕键盘难用** | dconf 系统默认：onboard 停靠底部 + Droid 主题 + 自动弹出 |
| DNS/下载/挂载各种小坑 | chroot DNS、保留 URL 扩展名 + magic 嗅探、`mkdir` 挂载点、选最大 ext4、去掉 `--info=progress2` |

### 硬件支持现状

内核/固件全部来自同一套 sheng mainline（全注入，**驱动层已同步**）；下列差异都是
**mainline 上游对个别外设支持不全**，非本镜像缺驱动。

| 硬件 | 状态 |
|---|---|
| 触摸 / WiFi / 蓝牙 | ✅ |
| 音频（含开机自愈） | ✅ |
| 120W 充电（MIPPS 认证） | ✅ |
| GPU / 显示 | ✅ |
| **传感器**（重力/陀螺/光感/霍尔） | ❌ 挂在 ADSP **SSC** 后面，需 `libssc` + SSC 版 `iio-sensor-proxy`（任何现成仓库都没有，得自己编）；配置文件 `sheng-sensors` 已在 |
| **相机** | ⚠️ 驱动/媒体图/传感器绑定都在，`libcamera` 也能识别并**抓原始帧**；但彩色卡在 libcamera 的 debayer **不支持该传感器 10-bit（R10_CSI2P）格式**。DDE 相机应用是 linglong 应用、假设高通私有栈，mainline 上多半用不了 |
| **触控笔**（小米焦点笔） | ❌ 内核只有**充电/配对**侧（`pen_*` @ pmic-glink），**无书写输入**（触摸数字转换器不报笔，私有协议未解码） |

### 已知问题（未解决）

| 问题 | 现状 |
|---|---|
| **登录界面白框** | DDE greeter 拿不到 Application Manager/主题（非原厂硬件的老毛病）；已开 autologin，不影响进桌面 |
| **maliit 屏幕键盘** | Wayland 优先，X11 下窗口显示不了；X11 只能用 onboard |
| **传感器 / 相机 / 触控笔** | 见上「硬件支持现状」——mainline 上游限制 |

## 怎么跑

1. 进本仓库的 **Actions** 页面；
2. 选 **Build Deepin 25 Desktop** → **Run workflow**；
3. 参数：
   - `kernel_version`：默认 `7.1`
   - `kernel_channel`：`stable`（默认）或 `mainline`
   - `boot_mode`：`single`（默认）/ `dual` / `all`
   - `deepin_src_url`：留空用官方 arm64 ISO；或填 deepin-ports 的 flat rootfs / 板级镜像 URL
4. 跑完在 **Artifacts** / **Release** 下载产物：
   - `deepin_<ver>_<mode>_<ts>.img.gz`（Android sparse rootfs 的 gzip）
   - `boot_sheng_singleboot.img`、`boot_sheng_dualboot.img`（**boot 镜像，由本仓库从同一内核 .deb 现场生成**）

> 解压 rootfs 得 `.img`（7-Zip 任意版本可解 `.gz`，或命令行）：
> - **Release**（分卷一条命令）：`cat deepin_*.img.gz.part.* | gzip -d > deepin.img`
> - **Artifacts**（zip 内是单个 `.img.gz`）：解出后 `gzip -d deepin_*.img.gz`

## 只构建 boot 镜像（轻量，不重建 rootfs）

只想要/重做 `boot_sheng_*.img`（比如已有 rootfs）时，跑 **Build boot images** workflow
（`build-bootimg.yml`）：纯 Python `mkbootimg`，跑在 `ubuntu-latest`（**不需要 arm runner**），
1~2 分钟，只下载内核 `.deb` 现场生成两个 boot 镜像。

## 刷机（本地，Windows/Linux/macOS 都行）

boot 镜像（`boot_sheng_*.img`）随本仓库产物一起下发（见上），由**同一次内核 .deb** 现场生成，和 rootfs 内核一致：

- `boot_sheng_singleboot.img` → `root=PARTLABEL=userdata`，配 `single` 模式 rootfs
- `boot_sheng_dualboot.img` → `root=PARTLABEL=linux`，配 `dual` 模式 rootfs

**单系统模式**（刷 `userdata`，抹掉 Android）：

```bash
fastboot erase dtbo_b
fastboot flash boot_b boot_sheng_singleboot.img
fastboot erase userdata
fastboot flash userdata deepin_25.2.0_single_<时间>.img
fastboot reboot
```

> **boot.img 与 rootfs 必须同一次内核构建**：都从上游同一个 Kernel Release 取即可。

### 双系统模式（Android + Linux 共存）

Android 在 **slot A**，Linux 在 **slot B**（`boot_b` + `linux` 分区），靠 A/B 槽切换。
需要先重分区腾出一个 `linux` 分区：

1. 进 TWRP：`adb reboot recovery`；把 `parted` 推到设备：`adb push parted /sdcard`
2. `adb shell` → `chmod +x /sdcard/parted && /sdcard/parted /dev/block/sda`
3. `print` 记下 `userdata` 的编号（一般 **29**）；`rm 29`
4. 建两个分区（大小按你的磁盘调整）：
   `mkpart userdata ext4 12.7GB 140.7GB` 和 `mkpart linux ext4 140.7GB -0MB`
5. `print` 确认 `userdata=29`、`linux=30`，然后 `quit`、`exit`

> ⚠️ 重分区会**清空 Android 的 userdata**（Android 系统本身还在，但应用数据没了）——先备份。

然后刷入 Linux（**用 `dual` 模式构建的产物**）：

```bash
fastboot erase dtbo_b
fastboot flash boot_b boot_sheng_dualboot.img
fastboot flash linux deepin_25.2.0_dual_<时间>.img
fastboot set_active b
fastboot reboot
```

首次启动后扩容：fstab 已带 `x-systemd.growfs`，开机自动撑满 `linux` 分区（根设备一般是 `/dev/sda31`；旧镜像才需手动 `sudo resize2fs <根设备>`）。

**切换系统**（fastboot，不需要 root）：

```bash
fastboot set_active b   # 进 Linux
fastboot set_active a   # 回 Android
```

> 上游明确警告：**别用 `qbootctl`**，会变砖。

### 推荐布局：`boot`=Android / `recovery`=Deepin（组合键进 Linux，不用切槽）

比上面“靠 A/B 槽切换”更省心：**正常开机永远是 Android，开机时按组合键进 Deepin**，
与当前活动槽无关。

| 分区 | 刷什么 | 启动方式 |
|---|---|---|
| `boot_a` / `boot_b` | **Android boot** | 正常开机 |
| `recovery_a` / `recovery_b` | **Deepin boot**（`boot_sheng_dualboot.img`） | **音量上＋电源** |
| `linux` 分区 | Deepin rootfs（`deepin_*.img`） | Deepin boot 用 `root=PARTLABEL=linux` 挂它 |

```bash
fastboot set_active a                                  # 正常开机 = Android
fastboot flash recovery_a boot_sheng_dualboot.img      # 组合键 → Deepin
fastboot flash recovery_b boot_sheng_dualboot.img      # 任何活动槽都对
fastboot reboot
```

之后：**关机 → 按住 `音量上` + `电源` → 进 Deepin**；直接开机 → Android。

> - 组合键因机型而异（音量上+电源 / 音量上单独 / 上下同按），试出你的那个即可。
> - 会覆盖 `recovery_a/b`（Android 的恢复模式没了；日常与 OTA 之外基本无感）；**可逆**。
> - 若某槽的 `boot_*` 仍是旧 Deepin boot，记得刷回 Android boot（“两槽都 Android”最稳）。
> - **升级内核**：`recovery_a` + `recovery_b` 一起换同一次构建的 boot；rootfs 单独刷 `linux`。
> - ABL 在 recovery 模式可能追加参数（如 `force_normal_boot=0`）——本内核无 ramdisk、
>   直接吃 `root=PARTLABEL=linux`，实测可正常启动；若冲突再单独做 recovery 专用 boot。

## 已知注意点

- **磁盘**：完整 Deepin 桌面 rootfs 约 10–20 GiB（官方 ISO 的完整根约 20 GiB），镜像按解压后大小自动定尺寸。
  workflow 里已加"释放磁盘空间"步骤；`dual` 模式会构建两个镜像、占用更大，
  建议优先 `single`。
- **源**：默认用 **官方 community arm64 ISO**（飞腾/鲲鹏取向）。可用 `deepin_src_url` 覆盖成其它镜像（脚本自动识别 ISO/tar/img.xz/zip）。
- **无 initramfs**：本方案复用的 `boot_sheng_*.img` **不带 ramdisk**，依赖内核内置
  UFS/ext4。
- **DDE 会话**：脚本 best-effort 配了 lightdm 自动登录；若 Deepin 25 用的不是
  lightdm，该文件无害。
- **首次启动**：fstab 已带 `x-systemd.growfs`，开机**自动**把根撑满分区（无需手动）。根分区是 `PARTLABEL=linux`（如 `/dev/sda31`，**不是** `sda30`）；只有旧镜像才需手动 `sudo resize2fs <根设备>`。

## USB 网络 / SSH（无需显示即可调试）

镜像内置 USB RNDIS/ECM 网卡 gadget + sshd：

- **设备 IP：`192.168.42.15`**（固定）
- Windows：接 USB 线后会出现一个新网卡（Remote NDIS…），把它设成 `192.168.42.1/24`：
  `netsh interface ip set address "以太网 <n>" static 192.168.42.1 255.255.255.0`
- 然后：`ssh luser@192.168.42.15`（密码 `luser`）
- 看启动问题：`systemctl --failed`、`journalctl -xb`

## 首次登录

默认 `luser/luser`、root `1234`。可在脚本里用环境变量 `ROOT_PASS` / `USER_PASS` /
`USER_NAME` 覆盖。

## 致谢

内核、固件、ALSA UCM 均源自上游 [code002-2/Xiaomi-pad-6s-pro-Linux](https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux)
与 [map220v](https://github.com/map220v) / [ianchb](https://github.com/ianchb)。
