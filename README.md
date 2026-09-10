# Deepin arm64 移植到小米平板 6S Pro（sheng）— GitHub Actions 构建

把 **Deepin 25（crimson）arm64** 用户态 + 本项目（code002-2/Xiaomi-pad-6s-pro-Linux）
的 sheng 内核/固件，做成可 `fastboot` 刷入的镜像。**全部在 GitHub Actions 云端构建**，
本地只用 `fastboot` 刷机。

## 为什么是"方案 B"（提取现成 rootfs）而不是 debootstrap

已核实：

- Deepin 官方社区源 `cdn-community-packages.deepin.com/deepin/dists/apricot/Release`
  的 `Architectures:` **只有 `amd64 i386`**，没有 arm64；`mirrors.ustc.edu.cn/deepin`
  也只有一个 `apricot` 套件。→ **无法对 Deepin 仓库 `debootstrap --arch=arm64`**。
- Deepin arm64 只通过 **deepin-ports** 以**预构建镜像**发布，deepin 25 代号
  **crimson**：
  - 通用 arm64：`https://cdimage.deepin.com/releases/25.2.0/arm64/deepin-desktop-community-25.2.0-arm64.iso`
  - 板级镜像：`https://cdimage.deepin.com/arm64/rock5/deepin-crimson-arm64-rock-5-itx-desktop.img.xz`

所以本方案：**取现成 arm64 用户态 → 摊平成 ext4 → 注入 sheng 内核 .deb + 设备修复 → 打成可刷 rootfs**。

> 内核/DTS/固件 **100% 复用**本项目 `sheng-kernel_build.sh` 的产出，完全不用动。

## 文件

| 文件 | 放到 fork 里的位置 |
|---|---|
| `sheng-deepin-rootfs_build.sh` | 仓库**根目录**（和 `lib/rootfs-common.sh` 同级） |
| `build-deepin.yml` | `.github/workflows/build-deepin.yml` |

两文件复用现有 `lib/rootfs-common.sh` 与 `.github/workflows/_rootfs-template.yml`。

## 安装到你的 fork

```bash
git clone https://github.com/<你>/Xiaomi-pad-6s-pro-Linux -b sheng
cp sheng-deepin-rootfs_build.sh <fork>/
mkdir -p <fork>/.github/workflows
cp build-deepin.yml <fork>/.github/workflows/
git -C <fork> add -A && git -C <fork> commit -m "add deepin rootfs" && git -C <fork> push
```

## 构建顺序（Actions 页面手动触发）

1. **Build Kernel** (`kernel.yml`) → 产出 `*.deb` + `boot_sheng_singleboot.img` / `boot_sheng_dualboot.img`，并发布 Release。
2. **Build Kernel Bundle** (`kernel-bundle-*.yml`) → 打包 `kernel-bundle-latest`（rootfs 流程从这里取 `.deb`）。
3. **Build Deepin 25 Desktop** (`build-deepin.yml`) → 产出 `deepin_25.2.0_<mode>_<时间>.7z`。

## 刷机（本地，Windows/Linux/macOS 都行）

单系统模式（刷 `userdata`，抹掉 Android）：

```bash
# 1. 解出内核启动镜像（来自第 1 步的 Release）
#    single → root=PARTLABEL=userdata ，与单系统 rootfs 匹配
fastboot erase dtbo_b
fastboot flash boot_b boot_sheng_singleboot.img

# 2. 解出 rootfs（.7z 里是 sparse .img）
7z x deepin_25.2.0_single_<时间>.7z
fastboot erase userdata
fastboot flash userdata deepin_25.2.0_single_<时间>.img
fastboot reboot
```

双系统模式则用 `boot_sheng_dualboot.img`（`root=PARTLABEL=linux`）并刷 `linux` 分区，
需先用 TWRP/parted 建好 `linux` 分区。

> **必须同一版内核**：`boot_sheng_*.img` 与 rootfs 里的 `/usr/lib/modules/<KVER>` 要来自
> 同一次内核构建（都从同一 Release 取即可）。

## 已知注意点 / 需要验证

- **源的选择**：默认用官方 arm64 ISO（其 squashfs 是 **live** 系统，可能带 live 残留，如
  自动登录/live 用户）。**更干净**的做法是指向 deepin-ports 的 **flat rootfs** 或**板级
  `.img.xz`**：改脚本顶部 `DEEPIN_SRC_URL` 即可（`.img.xz`/`.tar.xz`/`.zip` 均已支持）。
- **无 initramfs**：本项目的 `boot_sheng_*.img` **不带 ramdisk**（`sheng-kernel_build.sh`
  只 `--kernel`），依赖内核内置 UFS/ext4。Deepin rootfs 同样按此启动；若你的内核分支需要
  initramfs，得另加。
- **硬件用户态**：触摸校准、WiFi `board.bin` 别名、QRTR 服务已在脚本里调用
  （`configure_touchscreen` / `fix_wifi_firmware` / `setup_qrtr_service`）。触摸/音频依赖的
  内核侧驱动随内核 .deb 一起进来。
- **DDE 会话**：脚本 best-effort 配了 lightdm 自动登录；若 Deepin 25 用的不是 lightdm，
  该文件无害，按实际 DM 调整即可。
- **首次启动**：可能要 `sudo resize2fs /dev/sda30` 扩容（视分区而定）。

## 首次登录

默认 `luser/luser`、root `1234`。可用环境变量覆盖（在脚本或 workflow 里设）：
`ROOT_PASS` / `USER_PASS` / `USER_NAME`。
