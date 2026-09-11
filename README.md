# deepin-sheng-port

把 **Deepin 25（crimson）arm64** 用户态，配上小米平板 6S Pro（`sheng`，SM8550）的
sheng 内核/固件，做成可 `fastboot` 刷入的镜像。**全部在 GitHub Actions 云端构建**，
本地只用 `fastboot` 刷机。

本仓库的 sheng 内核/固件驱动均来自上游开源社区 —— 在此感谢 code002-2、 map220v、ianchb 等内核驱动开发者、deepin社区。

> 构建流程、修复清单、硬件支持现状、已知注意点、无线调试 → 见 **[DEVELOPMENT.md](DEVELOPMENT.md)**。

## 为什么是“提取现成 rootfs”而不是 debootstrap

- Deepin 官方社区源 `cdn-community-packages.deepin.com/deepin/dists/apricot/Release`
  的 `Architectures:` **只有 `amd64 i386`**，没有 arm64。→ 无法对 Deepin 仓库
  `debootstrap --arch=arm64`。
- Deepin arm64 只通过 **deepin-ports** 以**预构建镜像**发布（deepin 25 代号
  **crimson**）：官方 arm64 ISO、板级 `.img.xz`、`FlatBuild_*.zip`。

所以本仓库：**取现成 arm64 用户态 → 摊平成 ext4 → 注入 sheng 内核 .deb + 设备修复
→ 打成可刷 rootfs**。

## 下载

产物随每次构建下发，二选一：

- **GitHub Releases**（推荐）：本仓库 **Releases** 页，tag 形如 `deepin25-<n>`。超过 2 GiB
  的大镜像按 1900 MiB **分卷**成 `deepin_<ver>_<mode>_<ts>.img.gz.part.000`…
- **GitHub Actions Artifacts**：对应 workflow run 的 Artifacts（保留 7 天），zip 内是
  单个 `deepin_*.img.gz`。

每次构建同时产出 **rootfs** 与 **boot 镜像**（两者来自**同一次内核 .deb**，必须配套使用）：

| 文件 | 用途 |
|---|---|
| `deepin_<ver>_<mode>_<ts>.img.gz`（或 `*.part.*`） | rootfs（Android sparse，模式看产物名 `single`/`dual`） |
| `boot_sheng_singleboot.img` | 配 `single` rootfs，`root=PARTLABEL=userdata` |
| `boot_sheng_dualboot.img` | 配 `dual` rootfs，`root=PARTLABEL=linux` |

## 合并

**Linux / macOS**

Releases（分卷，拼接 + 解压一条命令）：

```bash
cat deepin_*.img.gz.part.* | gzip -d > deepin.img
```

Artifacts（zip 里是单个 `.img.gz`）：

```bash
gzip -d deepin_*.img.gz
```

**Windows（CMD / PowerShell）**

Releases（分卷，用 `copy /b` 拼接，在分卷所在目录执行）：

```bat
copy /b deepin_*.img.gz.part.* deepin.img.gz
```

> 若担心通配拼接顺序，也可显式按序列出各分卷：
> ```bat
> copy /b deepin_*.img.gz.part.000+deepin_*.img.gz.part.001+deepin_*.img.gz.part.002+deepin_*.img.gz.part.003+deepin_*.img.gz.part.004+deepin_*.img.gz.part.005 deepin.img.gz
> ```

Windows 解压 `.gz`（任选其一，解出 `deepin.img`）：

```bat
:: Win10 1803+ 自带 tar
tar -xf deepin.img.gz

:: 或装 7-Zip
7z x deepin.img.gz
```

解出来就是 Android sparse rootfs `.img`（magic `3aff26ed`），刷机直接用。

## 刷机

> **boot 镜像与 rootfs 必须是同一次内核构建的产物**（都从上游同一个 Kernel Release 取即可）。

### 单系统模式（刷 `userdata`，抹掉 Android）

```bash
fastboot getvar current-slot        # 查看当前活动槽位（一般为 a）
fastboot erase dtbo_b
fastboot flash boot_b boot_sheng_singleboot.img
fastboot set_active b               # ★ 切到 B 槽；漏了这步刷完也不进 Deepin
fastboot erase userdata
fastboot flash userdata deepin_25.2.0_single_<时间>.img
fastboot reboot
```

> 单系统把 Deepin 放 **slot B**，`boot_b` 刷完必须 `set_active b` 才会从 B 槽启动。

### 双系统模式（Android + Linux 共存）

#### 准备：重分区腾出 `linux` 分区（两种方式都需要）

Android 原本占满整个磁盘，先重分区。进 TWRP：

1. `adb reboot recovery`；把 `parted` 推到设备：`adb push parted /sdcard`
2. `adb shell` → `chmod +x /sdcard/parted && /sdcard/parted /dev/block/sda`
3. `print` 记下 `userdata` 的编号（一般 **29**）；`rm 29`
4. 建两个分区（大小按你的磁盘调整）：
   `mkpart userdata ext4 12.7GB 140.7GB` 和 `mkpart linux ext4 140.7GB -0MB`
5. `print` 确认 `userdata=29`、`linux=30`，然后 `quit`、`exit`

> ⚠️ 重分区会**清空 Android 的 userdata**（Android 系统本身还在，但应用数据没了）——先备份。

#### 方式一：`recovery` 分区放 Deepin boot（组合键进 Linux，推荐）

比下面“靠 A/B 槽切换”更省心：**正常开机永远是 Android，开机时按组合键进 Deepin**，
与当前活动槽无关。

| 分区 | 刷什么 | 启动方式 |
|---|---|---|
| `boot_a` / `boot_b` | **Android boot** | 正常开机 |
| `recovery_a` / `recovery_b` | **Deepin boot**（`boot_sheng_dualboot.img`） | **音量上＋电源** |
| `linux` 分区 | Deepin rootfs（`deepin_*.img`） | Deepin boot 用 `root=PARTLABEL=linux` 挂它 |

```bash
fastboot flash recovery_a boot_sheng_dualboot.img      # 先把 Deepin boot 刷进 recovery
fastboot flash recovery_b boot_sheng_dualboot.img      # 两槽都刷（任何活动槽都对）
fastboot set_active a                                  # 再让正常开机 = Android
fastboot reboot
```

之后：**关机 → 按住 `音量上` + `电源` → 进 Deepin**；直接开机 → Android。

> - 组合键因机型而异（音量上+电源 / 音量上单独 / 上下同按），试出你的那个即可。
> - 会覆盖 `recovery_a/b`（Android 的恢复模式没了；日常与 OTA 之外基本无感）；**可逆**。
> - 若某槽的 `boot_*` 仍是旧 Deepin boot，记得刷回 Android boot（“两槽都 Android”最稳）。
> - **升级内核**：`recovery_a` + `recovery_b` 一起换同一次构建的 boot；rootfs 单独刷 `linux`。
> - ABL 在 recovery 模式可能追加参数（如 `force_normal_boot=0`）——本内核无 ramdisk、
>   直接吃 `root=PARTLABEL=linux`，实测可正常启动；若冲突再单独做 recovery 专用 boot。

#### 方式二：A/B 槽切换（Android=slot A，Deepin=slot B）

Linux 放 **slot B**（`boot_b` + `linux` 分区），靠 A/B 槽切换。刷入 **`dual` 模式**的产物：

```bash
fastboot erase dtbo_b
fastboot flash boot_b boot_sheng_dualboot.img
fastboot flash linux deepin_25.2.0_dual_<时间>.img
fastboot set_active b
fastboot reboot
```

切换系统（fastboot，不需要 root）：

```bash
fastboot set_active b   # 进 Linux
fastboot set_active a   # 回 Android
```

> 上游明确警告：**别用 `qbootctl`**，会变砖。

### 首次启动后扩容

fstab 已带 `x-systemd.growfs`，开机**自动**把根撑满分区（无需手动）。根分区是
`PARTLABEL=linux`（如 `/dev/sda31`，**不是** `sda30`）；只有旧镜像才需手动
`sudo resize2fs <根设备>`。

## 首次登录

默认 `luser/luser`、root `1234`。可在脚本里用环境变量 `ROOT_PASS` / `USER_PASS` /
`USER_NAME` 覆盖。

## 致谢

感谢三位内核驱动开发者：[code002-2](https://github.com/code002-2)、[map220v](https://github.com/map220v)、[ianchb](https://github.com/ianchb)——
本项目的内核、固件、ALSA UCM 均源自他们的工作。
