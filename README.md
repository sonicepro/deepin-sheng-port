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

## 怎么跑

1. 进本仓库的 **Actions** 页面；
2. 选 **Build Deepin 25 Desktop** → **Run workflow**；
3. 参数：
   - `kernel_version`：默认 `7.1`
   - `kernel_channel`：`stable`（默认）或 `mainline`
   - `boot_mode`：`single`（默认）/ `dual` / `all`
   - `deepin_src_url`：留空用官方 arm64 ISO；或填 deepin-ports 的 flat rootfs / 板级镜像 URL
4. 跑完在 **Artifacts** 下载 `deepin25-rootfs-<mode>`（`.7z`，完整文件），或从自动创建的
   Release 下载。

> Release 单资产上限 **2 GiB**：超过会分卷成 `*.part.000`、`*.part.001` …
> 合并：`cat deepin_*.7z.part.* > deepin.7z`（Artifacts 里的则是完整 `.7z`，无需合并）。

## 刷机（本地，Windows/Linux/macOS 都行）

内核启动镜像从上游 **Kernel stable** Release 取：

- `boot_sheng_singleboot.img` → `root=PARTLABEL=userdata`，配 `single` 模式 rootfs
- `boot_sheng_dualboot.img` → `root=PARTLABEL=linux`，配 `dual` 模式 rootfs

**单系统模式**（刷 `userdata`，抹掉 Android）：

```bash
fastboot erase dtbo_b
fastboot flash boot_b boot_sheng_singleboot.img

7z x deepin_25.2.0_single_<时间>.7z
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

7z x deepin_25.2.0_dual_<时间>.7z
fastboot flash linux deepin_25.2.0_dual_<时间>.img
fastboot set_active b
fastboot reboot
```

首次启动后扩容：`sudo resize2fs /dev/sda30`（`linux` 分区）。

**切换系统**（fastboot，不需要 root）：

```bash
fastboot set_active b   # 进 Linux
fastboot set_active a   # 回 Android
```

> 上游明确警告：**别用 `qbootctl`**，会变砖。

## 已知注意点

- **磁盘**：完整 Deepin 桌面 rootfs 约 10 GiB，镜像按解压后大小自动定尺寸。
  workflow 里已加"释放磁盘空间"步骤；`dual` 模式会构建两个镜像、占用更大，
  建议优先 `single`。
- **源的选择**：默认官方 ISO 的 squashfs 是 **live** 系统（可能带 live 残留）。
  更干净的是 deepin-ports 的 **flat rootfs** 或**板级 `.img.xz`**——
  用 `deepin_src_url` 一行覆盖即可（脚本自动识别 ISO/tar/img.xz/zip）。
- **无 initramfs**：本方案复用的 `boot_sheng_*.img` **不带 ramdisk**，依赖内核内置
  UFS/ext4。
- **DDE 会话**：脚本 best-effort 配了 lightdm 自动登录；若 Deepin 25 用的不是
  lightdm，该文件无害。
- **首次启动**：视分区可能需要 `sudo resize2fs /dev/sda30` 扩容。

## 首次登录

默认 `luser/luser`、root `1234`。可在脚本里用环境变量 `ROOT_PASS` / `USER_PASS` /
`USER_NAME` 覆盖。

## 致谢

内核、固件、ALSA UCM 均源自上游 [code002-2/Xiaomi-pad-6s-pro-Linux](https://github.com/code002-2/Xiaomi-pad-6s-pro-Linux)
与 [map220v](https://github.com/map220v) / [ianchb](https://github.com/ianchb)。
