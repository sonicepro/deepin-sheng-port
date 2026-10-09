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

### openKylin 3.0：开机登录方式（autologin + 立即锁屏）

**目标**：开机既要**密码**、又**不卡**。做法 = lightdm **自动登录 + 登录后立即锁屏**：桌面会话在开机阶段就在锁屏**后面**预载好，用户看到的是锁屏，输密码只是解锁 → **秒进**（若用普通 greeter，会话要等输完密码才开始加载 → 明显等一截）。

构建步骤 7 做两件事（开关 **`AUTOLOGIN_ENV`，默认开**；设 `0` 则回到普通 ukui-greeter）：
1. **`setup_lightdm_autologin`** 写 `/etc/lightdm/lightdm.conf.d/00-sheng-autologin.conf`
   （`[Seat:*]` + `autologin-user=<user>` + `autologin-user-timeout=0`）→ lightdm 开机以 `lightdm-autologin` 服务直接进用户会话（日志 `Started with service 'lightdm-autologin'`、`Authentication complete ... Success`）。
2. **`install_lock_on_login`** 落 `/usr/local/bin/sheng-lock-on-login` + `/etc/xdg/autostart/sheng-lock-on-login.desktop`，会话起来后**立即锁屏**。

- ⚠️ **lightdm 自带的 autologin 锁屏键是死的**：`autologin-user-lock` / `enable-autologin-user-lock`（`97-ukui-greeter-wlcom.conf` 里那个）在本机**都不生效**（实机验证：自动登录后仍是解锁桌面；`enable-` 那个还被 lightdm 报 `unknown option`）。锁屏由我们自己的 `sheng-lock-on-login` 做。
- **锁屏为什么能“盖在桌面上”**：该 XDG autostart 项用 **`X-UKUI-Autostart-Phase=Initialization`**（和 `ukui-screensaver` 同一 phase），于是在 `Panel`/`Application`（ukui-panel、peony-desktop 等）**之前**就锁屏；脚本**后台 detach**（`setsid … --worker`）等 `ukui-screensaver-backend` 拿到会话总线名 `org.ukui.ScreenSaver` 后调 `ukui-screensaver-command --lock`。⚠️ 不设 phase（默认落到 `Application`）会退化成“桌面加载完才锁屏”。
- ⚠️ 与「息屏要不要密码」是**两回事**：后者由 `org.ukui.screensaver close-activation-enabled` 控制（默认 `true`，见「电源键关闭显示器」一节）；本项只管**开机首次登录**。
- ⚠️ **改登录/会话相关配置后不要 `systemctl restart lightdm` 就地生效** —— 那会在 KMRE（安卓）显示仍连着时杀掉合成器 → `arm-smmu … Unhandled context fault` **花屏**（实测踩过）。**一律用重启**（`systemctl reboot`）生效。

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

### openKylin 3.0：自动亮度（ADSP SSC 环境光 → UKUI 亮度）

同一构建循环里有 **`install_autobrightness`（步骤 6a-2；开关 `AUTOBRIGHTNESS_ENV`，默认开）**，
让平板**自动亮度**开箱即用。链条与根因（真机逐一验证）：

- **光感 = ADSP SSC 环境光**（`stk3bcx`），走 **libssc**：`ssccli --sensor light` 输出
  `Light sensor measurement: N Lux`（本机固件的光感**可用**；与加速度计不同，没有导致
  iio-sensor-proxy 崩的 `measurement_id` 缺失问题）。
- **亮度 = 会话 D-Bus** `org.ukui.SettingsDaemon /GlobalBrightness` 的
  `org.ukui.SettingsDaemon.Brightness.setPrimaryBrightness(u)`（与手动亮度滑块同一条路，走合成器
  gamma；见「亮度持久化」）。
- **开关 = 控制中心「显示」页写的 gsettings 键**
  `org.ukui.SettingsDaemon.plugins.auto-brightness auto-brightness`（`libdisplay.so` 里可见）。守护
  进程只在该键为 true 时才动亮度；并写 `have-sensor=true`（`GlobalSignal.isPresenceLightSensor`）让
  开关可见。**注意**：`active` 是“插件是否被加载”的键，与开关无关。
- **不能用 openKylin 自带自动亮度插件**（`libauto-brightness.so` → `AutoBrightnessManager`）：它确实
  通过 Qt5 Sensors 读光感（`net.hadess.SensorProxy.LightLevel`，本机可用），但其
  `adjustBrightnessWithLux` 是经内部 **`BrightThread`**（`getRealTimeBrightness`/`setBrightness`）施加
  亮度的，在本机 Wayland/kylin-wlcom 上**无任何效果**——真机实测：开灯/关灯、甚至用它自带的
  `debug-lux`（`debug-mode=true` 后扫 `debug-lux`）亮度都纹丝不动。故障在编译好的二进制内部，故改用
  自带守护进程。
- **`sheng-autobrightness` 守护进程**：跑 `ssccli --sensor light` 读 lux → EMA 平滑 → 分段对数曲线
  映射为亮度百分比（约暗 15% … 强光 100%）→ `dbus-send` 调 `setPrimaryBrightness`。**防抖**：目标
  变化后要**稳定保持 ≥2.5s**（`SETTLE`）才真正写亮度，另有输出死区（≥3%）与写入间隔（≥2.5s）；快速
  光线抖动（闪烁灯管/掠过阴影）会不断重置稳定窗口，故屏幕不闪。数值可用环境变量
  `SHENG_AUTOBRIGHTNESS_{EMA,DEADBAND,MIN_INTERVAL,SETTLE,SETTLE_EPS}` 覆盖，无需重编镜像。
  **以 `luser` 跑**（session bus 只认 uid 1000）。
  该值最终经 `globalconf.ini [color]` 由 **`sheng-panel-brightness` 引擎落到真实背光**（见「屏幕亮度
  = 真实背光」），不再是合成器软件亮度。
- 落地文件：`system_files_openkylin/usr/local/bin/sheng-autobrightness`、
  `system_files_openkylin/etc/systemd/user/sheng-autobrightness.service`（enable 软链由构建为用户建）。

#### 用户偏置：把手动调的亮度作为自动亮度的「基准」（2026-10 加入）

**问题**：上面的曲线是lux→亮度的**固定映射**。当它给的亮度偏暗、用户手动往上调之后，曲线下一次
决定动屏幕时会把用户的选择**覆盖掉**——这就是「自动亮度后面还会让屏幕变暗」的根因。

**做法**：记录**用户设定值**与**曲线在当时的取值**之差，作为持久偏置 `bias`，此后一律按

```
applied = clamp(curve(lux) + bias, 1, 100)
```

输出。于是「暗房里手动 +15」在光线变化后仍然是相对曲线 +15：手动值在被调的那一刻被**精确保留**
（`bias := manual - curve(lux_now)`，所以 `curve+bias == manual`，当场不会被拉回），之后作为基准一路
跟随。

**手动调整怎么识别**：守护进程轮询会话总线上**当前**的 UKUI 亮度
（`getPrimaryBrightness`，与滑块写的是同一个 0..100 值），把**不是自己写出的变化**当作手动调整。要点：

- **绝不与自己的写入打架**：自己写完后 `WRITE_GRACE`（默认 2.5s）内的回读一律忽略；且候选新值必须
  **连续两次读到**才被采信——总线回读延迟、bridge 回环造成的瞬时抖动不会被误判成用户操作。
- **开关为关时也会识别**：所以「关掉自动亮度 → 调到喜欢的亮度 → 再打开自动亮度」是生效的。
- **持久化**在 `~/.config/sheng/autobrightness.conf`，可跨挂起 / 会话重启 / 重启存活。删掉该文件或
  `sheng-autobrightness --reset-offset` 即回到纯曲线（运行中的守护进程会在 ~0.5s 内自动拾取）；
  `sheng-autobrightness --status` 打印当前偏置与实时亮度。
- **偏置不额外设上限**（只受 1..100 输出钳制）：用户把滑块拉到 100，自动亮度就必须停在 100，不能
  「为了安全」把它压回某个值——否则又会重现本 bug。需要收窄可用
  `SHENG_AUTOBRIGHTNESS_MAX_OFFSET`。
- 其他可调项：`SHENG_AUTOBRIGHTNESS_{USER_BIAS,MANUAL_TOL,WRITE_GRACE,READ_INTERVAL,BIAS_STEP}`。
- 顺手修的健壮性问题：`kylin-process-manager` 进入 idle 场景时会有一段时间任何进程都打不开
  `/dev/null`（真机实测 21:18–21:26 共 94 次 `[Errno 13] Permission denied: '/dev/null'`），
  而旧代码用 `stderr=subprocess.DEVNULL` 起 `ssccli`，于是**自动亮度与自动转屏同时瘫掉**约 8 分钟。
  现在起读取进程失败会退回 `stderr=STDOUT`（不需要 `/dev/null`），其余小命令也改用
  `capture_output=True`，整个守护进程不再依赖 `/dev/null`。

> 真机验证（2026-10-08 21:58–22:04，`--debug`）：曲线 41% 时手动调到 60% → 日志
> `manual brightness 60% at lux=31.2 (curve says 41%) -> user bias +19.0%`，随后 14s 内亮度**稳定停在
> 60%（不再被拉回 41%）**；重启服务后 `user bias +19.0% loaded`，亮度仍是 60%。离线仿真脚本
> 覆盖学习 / 跟随 / 重启不回落 / 回读延迟不产生幻影偏置 / 单帧抖动忽略 / 在线 reset 六种场景。
>
> **「幻影偏置」专项排查（重要）**：本设计把**任何**非自身写入都当手动调整，所以必须先确认本机
> **没有会自动改亮度的东西**（空闲降亮度 / 电源策略），否则会把它们学成偏置、越用越暗。实测：
> 让用户完全不动手，用 `dbus-monitor` 盯 `org.ukui.SettingsDaemon` 2.5 分钟——期间落到总线上的
> `setPrimaryBrightness` 只有 **守护进程自己 + 亮度桥接回环**两次（`sender` 均为一次性 `dbus-send`/
> `busctl` 连接），**零次第三方调用**；同时设备正处于**电池放电(52%) + `idle-dim-battery=true` +
> `idle-dim-time=60`**，空闲降亮度本该触发却毫无动静。这与「upm 的亮度通道在本机是死的」一致
> （见「亮度滑块桥接」），因此**不需要**再加 logind 空闲守卫——结论是有证据的，不是假设。
> 排查中确认 `getPrimaryBrightness` 被桥接以 1s 周期调用，单次 `busctl` 约 7ms，守护进程稳态
> CPU 0.3%，故 0.5s 轮询的代价可忽略。

> 与自带插件可能“双重控制”：本守护进程默认生效、而自带插件默认 `active=false`（不加装它）。
> 若日后用户手动把插件 `active` 打开、且它在新环境里又能工作，可能两者抢亮度，届时二选一。

### openKylin 3.0：屏幕亮度 = 真实背光（干掉合成器软件亮度「滤镜」）

构建步骤 **6c（开关 `BRIGHTNESS_FIX_ENV`，默认开）** 给 `ukui-settings-daemon` 打补丁，步骤
**6a-5（开关 `PANEL_BRIGHTNESS_ENV`，默认开）** 落地背光引擎。两者配合：屏幕亮度全部由**真实
面板背光**承担，彻底不再用合成器「软件亮度」——它对像素做乘法（`color *= brightness`），是压暗部、
让暗场景发灰的**滤镜**。

- **亮度控制是谁**：快捷操作条（`ukui-sidebar` 的 `libbrightness-shortcut.so`）、设置→显示器
  （`ukui-control-center` 的 `libdisplay.so`，经本仓库「亮度滑块桥接」）、托盘、自动亮度都走会话
  D-Bus `org.ukui.SettingsDaemon` 对象 `/GlobalBrightness` 的 `setPrimaryBrightness(u)`（即
  `ukui-settings-daemon` 的 gamma-manager）。它把用户值(0..100)持久化到
  `/etc/ukui/usd/globalconf.ini` 的 `[color] <output>=<v>`，并下发合成器软件亮度。
- **真机验证的关键事实**：`globalconf.ini [color]` 的值是**忠实的用户值**，且与合成器亮度**解耦**
  ——把合成器 `com.kylin.Wlcom.Output.SetBrightness` 直接钉到任意值（如 100），该 config 与
  `getPrimaryBrightness` **都不变**。所以它是稳定的控制通道（这正是一切设计的基础）。
- **根因①（转屏/重启回最亮）**：`UsdBaseClass::upmSupportAdjustBrightness()` 只判断
  `/sys/class/backlight/*/brightness` 是否存在 → 本平板有 `ktz8866-backlight` → 返回 true →
  gamma-manager 把**唯一内屏**当"笔记本内屏"，在 `GmHelper::updateWlcomOutputInfo()` 里
  `targetBrightness=100`，**每次输出重配置（转屏）和会话启动**都拉满。而 upm 其实调不了该节点
  （`org.ukui.powermanagement.CanSetBrightness=false`）。→ 让该函数返回 false（`mov w0,#0; ret`）。
  源码补丁见 `docs/patches/ukui-settings-daemon-upmSupportAdjustBrightness.patch`。
- **根因②（滤镜）**：gamma-manager 把用户值经 `GmHelper::normalizeBrightness` 映射后下发合成器
  `SetBrightness`，合成器对像素做乘法 → 滤镜。→ 把 `normalizeBrightness` / `denormalizeBrightness`
  两个函数体钉成**常量 100**（`mov w0,#100; ret`，`SHENG_COMPOSITOR_BRIGHTNESS` 可改）→ 合成器
  永远 100（=不减光）= **无滤镜**。（原本映射是 `30 + user×0.7`。）
- **背光引擎 `sheng-panel-brightness`**（`system_files_openkylin/usr/local/bin/sheng-panel-brightness`
  + 用户级服务）：监视 `globalconf.ini` 的 `[color] <output>` 值 → 线性映射写入
  `/sys/class/backlight/ktz8866-backlight/brightness`（`level = BL_MIN + (BL_MAX−BL_MIN)×v/100`，
  默认 `BL_MIN=15`、`BL_MAX=2047`，可用 `SHENG_BACKLIGHT_MIN/MAX` 覆盖）。这样三条 UI 路径一起
  驱动真实背光。**以 `luser` 跑**（该节点本机对 `luser` 可写）。
- **落地方式**：`tools/sheng-usd-brightness-fix.sh` 对**已编译**的二进制打机器码补丁（openKylin
  仓库版本错位——`libxrandr-dev` 1.5.2 vs 设备 1.5.4——导致设备上源码编译 `ukui-settings-daemon`
  失败）：用 `nm -DC` 找符号、`readelf -SW` 把 vaddr 换算成文件偏移，只读 arm64 ELF 字节，x86
  构建机也能跑；`upmSupportAdjustBrightness` 在 **daemon 主程序 + 每个导出该符号的插件 `.so`**（符号
  会被 interpose）各打一份。⚠️ **写这些文件前必须先停掉 `ukui-settings-daemon`**，否则 mmap 重取页
  → SIGBUS（实测 core dump）。
- **废弃**：旧的 `sheng-backlight-fixed.service`（开机把背光钉死 1800）**已移除**——它会和新引擎抢
  背光。背光现在由引擎按 UI 值驱动；`sheng-suspend-backlight` 仍在挂起/恢复时关/还原背光（与引擎
  兼容：恢复回引擎当前值）。
- 验证（真机）：`setPrimaryBrightness 30/8/70/100` → config 同步 `30/8/70/100`，背光
  `828/177/1437/2047`；`gsettings set org.ukui.power-manager brightness-ac 30` → 背光 625。合成器
  `brightness` 恒 100（`busctl --user call com.kylin.Wlcom /com/kylin/Wlcom/Output
  com.kylin.Wlcom.Output ListAllOutputs` 可见）。

### openKylin 3.0：「设置 → 显示器」亮度滑块（拖动无效 → 桥接）

控制中心**「设置 → 显示器」页**的亮度滑块真机拖动无反应（**侧栏/快捷中心/托盘都正常**）。实机 + 反汇编定位：

- 该滑块是 `ukui-control-center` 的 `libdisplay.so`。走哪条路由 `Widget::isSetGammaBrightness()` 决定，**本机恒为 `false`**：upm（`org.ukui.powermanagement`）在注册但 `CanSetBrightness=false`、DMI 产品名既非 `VAH510` 也非 `all in one`、schema 里没有 `gammaforbrightness` 键。→ 滑块**只写 gsettings `org.ukui.power-manager brightness-ac`**（硬件背光路），**一次都不调**能用的 `setPrimaryBrightness`（gamma 路）。抓包实证：拖动只产生一串 `ca.desrt.dconf.Write … /org/ukui/power-manager/brightness-ac`，无任何 `org.ukui.SettingsDaemon`/合成器调用。
- `brightness-ac` 的落地点是 **upm 硬件背光**（写它会触发 `org.ukui.powermanagement.RegulateBrightness`），而本机 upm 驱动不了 `ktz8866`（`RegulateBrightness` 返回 `"no effective node"`，`CanSetBrightness=false`）→ **拖动无效**。
- 侧栏/快捷中心直接调 `org.ukui.SettingsDaemon /GlobalBrightness` 的 `setPrimaryBrightness` → gamma-manager → 合成器 `SetBrightness` → 正常。这也是本滑块要接上的目标路径。

**修法（构建步骤 6a-3，开关 `BRIGHTNESS_BRIDGE_ENV`，默认开）**：加用户级守护 `sheng-brightness-ac-bridge`，把两条路接起来：`brightness-ac` 变化 → `setPrimaryBrightness(uint32)`（滑块能真正改亮度）；当前亮度 → 回写 `brightness-ac`（滑块位置反映真实亮度）。**不碰任何二进制**。落地文件：`system_files_openkylin/usr/local/bin/sheng-brightness-ac-bridge`、`etc/systemd/user/sheng-brightness-ac-bridge.service`（enable 软链由构建为用户建）。
- 守护**不在启动时主动施加**（`brightness-ac` 默认 `100.0`，登录时施加会把亮度顶满）；反向同步在 `brightness-ac` 连续变化（拖动）时被抑制、并有 ±3 容差，不会和拖动打架。
- **⚠️ 反向同步（当前亮度 → `brightness-ac`）自 2026-10 起默认关闭**，见下节「转屏时亮度被顶到 100%」：`brightness-ac` 是 ukui-settings-daemon 的**输入键**，回写它会把 usd 的转屏故障"上膛"。要恢复旧行为设 `SHENG_BRIDGE_MIRROR=1`。正向（滑块 → 真实亮度）**未改动**，实测仍然有效（`brightness-ac=60 → primary=60`、`50 → 50`）。

> ⚠️ 更正：早前（记忆 `sheng-brightness-reset-fix`）把「设置→显示器」也归为走 `setPrimaryBrightness` 是**错的**——实测它写的是 `brightness-ac`，正因如此才需要本桥接。

### openKylin 3.0：转屏（横竖屏切换）时亮度被顶到 100%

**症状**：横屏切竖屏（或反向）时，屏幕亮度**有时**被顶到很亮，甚至 `100%`。

**定位过程与实证**（真机 `dbus-monitor` + dconf 写入字节解码 + 反复转屏守株待兔）：

1. **不是** 构建补丁失效：`upmSupportAdjustBrightness` 在 daemon 与全部插件里都已是 `mov w0,#0; ret`；且把 `sheng-autobrightness` 与桥接都停掉后，反复转屏在 `30/20/55/62/95/100%` 下**一动不动**。补丁有效。
2. **抓到一次现行**：`dbus-monitor` 全程只出现 **一次** 对 `brightness-ac` 的写入，其 dconf `Change` 负载解码为
   key = `/org/ukui/power-manager/brightness-ac`，value = `0x4057000000000000`(double) = **92.0**，
   发送者是一个**一次性连接**（`:1.596`）——即本仓库桥接的反向同步；紧随其后的 `setPrimaryBrightness(92)` 也是桥接的正向转发。
3. **时间线**：桥接在 11:37:19 因亮度变成 59 而回写 `brightness-ac=59`（**给 usd 上膛**）→ 14 秒后转屏 → usd 重配置输出时**重新施加了这个"最近被写过"的 `brightness-ac`**，而本机的施加路径是坏的，把 59 放大成 **92**，再一次转屏变成 **100**（观测到 51→78、73→99、59→92→100 等多组）。停掉桥接后 `brightness-ac` 从不被写，故长时间转屏毫无反应——两端证据闭环。
4. 叠加放大：新加的用户偏置会把这种跳变**当成手动调整学下来**（`manual brightness 100% ... -> user bias +42.0%`），于是屏幕**锁死在很亮**，这才是"有时候一直很亮"的原因。

**修法（两层，均不碰二进制）**：

- `sheng-brightness-ac-bridge`：**不再回写 `brightness-ac`**（反向同步改为 `SHENG_BRIDGE_MIRROR=1` 才开）。根因是写 usd 的输入键，去掉它就没有上膛源。代价仅是该滑块位置不再实时反映亮度。
- `sheng-autobrightness`：轮询合成器输出几何（`ListAllOutputs` 的 `transform/scale/width/height/enabled`，**刻意不含 `brightness`**）来识别"屏幕重配置"。重配置后 `RECONF_WINDOW`（默认 5s）内出现的**外部亮度变化一律不学成偏置**，只记日志；若跳变 ≥ `GLITCH_JUMP`（默认 15）则**立即**纠正（绕过 `SETTLE`），所以屏幕只会闪一下而不是停在错误值。窗口外的手动调整照常学习（回归测试覆盖）。

**仍存在的缺口（后续可做）**：控制中心「设置→显示器」滑块**自己**也会写 `brightness-ac`，所以拖过它之后仍可能给 usd 上膛一次。彻底修法是不让任何人写这个键：把 `ukui-control-center` 的 `libdisplay.so` 改成直接调 `setPrimaryBrightness`（或把它写的键改成本仓库自己的 gsettings 键，需一并提供 schema），那之后本桥接就可以整个删掉。届时 `sheng-autobrightness` 的重配置守卫仍作为兜底。

> 回归测试：`tools/test-sheng-autobrightness-bias.py` 第 7 项模拟"重配置后 32→65"的跳变，断言**不学偏置**且**立即恢复 32**；第 8 项断言窗口过后的真实调整仍被学习（+18）。8/8 通过。

### openKylin 3.0：休眠时立即关背光（消除"黑屏但背光还亮"）

点「休眠」后会先出现一小段"**屏幕已黑、但背光还亮**"，过一会背光才灭。真机定位（logind + 合成器 + 驱动时序）：

- logind 收到休眠请求**先发 `PrepareForSleep(true)`** → 合成器 `kylin-wlcom`（有 `PrepareForSleep`/`PrepareForSuspend`/`Power off outputs` 字样）**立即关输出**（画面黑）——**不动背光**。
- 之后 logind 要**等一批 `delay` inhibitor 放行**（实测挂着的：`Screen Locker`/`Screen Locker Backend`、`kylin-process-manager`（Process Manager Idle）、`qq`（×2）、`NetworkManager`、`UPower`），才真正让内核进 `PM: suspend entry (s2idle)`。
- **背光是在内核 suspend 时才由 DSI 面板 + `ktz8866` 驱动一起切断的**；中间那段 = 等 inhibitor 的时间。系统里**没有任何 sleep hook 写 `/sys/class/backlight`**（`systemd-sleep` 下只有 `hdparm`）。

**修法（构建步骤 6e，开关 `SUSPEND_BACKLIGHT_ENV`，默认开）**：系统级守护 `sheng-suspend-backlight` 监听系统总线 logind 的 `PrepareForSleep`：收到 `true` 立刻把背光写 `0`（保存原值），收到 `false`（恢复/取消）还原。落地文件：`system_files_openkylin/usr/local/sbin/sheng-suspend-backlight`、`etc/systemd/system/sheng-suspend-backlight.service`（构建 enable）。真机验证：`busctl --system emit /org/freedesktop/login1 org.freedesktop.login1.Manager PrepareForSleep b true/false` → 背光 `1800→0→1800` ✅。

> 注：当前挂着 `ukui-powermanagement` 的 `block handle-lid-switch`（合盖被禁），此服务对**手动休眠/电源键**生效。

> 另：**logind `InhibitDelayMaxSec`（默认 5s）** 会放大"屏幕灭 → 真正睡"的窗口——它要等 `kylin-process-manager` 的 sleep delay 锁放行（实测放到超时才放）。构建步骤 **6f**（开关 `INHIBIT_FIX_ENV`）装 logind drop-in `/etc/systemd/logind.conf.d/10-sheng-inhibit.conf` 把 `InhibitDelayMaxSec` 设为 **1s**。⚠️ **改它别在运行中 `systemctl restart systemd-logind`**（会打断图形会话、掉到控制台）；开机生效即可。（注：suspend→resume 本身仍有 s2idle 往返开销，这步只去掉可避免的"挂起前等待"。）

### openKylin 3.0：电源键「关闭显示器」（下拉加项 + 真正关屏）

控制中心「设置 → 电源 → 按下电源键时执行」下拉**原本没有「关闭显示器」**。构建步骤 **6g（开关
`POWER_BLANK_ENV`，默认开；脚本 `tools/sheng-power-button-blank-fix.sh`）** 把它补齐。这是**两条链**（真机逐一验证）：

- **下拉列表写死在控制中心电源插件**：插件是 `ukui-power-manager` 包的
  `usr/lib/aarch64-linux-gnu/ukui-control-center/libpower.so`（dpkg 已把它 divert 覆盖 `ukui-control-center` 自带的那份）。
  `Power::setupComponent()` 的选项**硬编码**为 Interactive / Shutdown / Suspend / Hibernate —— 没有 `blank`。
  而 gsettings enum（`org.ukui.power-manager button-power`）与 `ukui-framework-dbus` 的属性
  `org.ukui.Framework.Devices.Power.PowerButtonAction` **本就接受 `blank`**，合成器 `kylin-wlcom` 也实现了 KDE
  DPMS 协议（`kscreen-doctor -d off/on` 有效）。→ 只是**下拉漏了该项**。
- **真正处理电源键的是 `ukui-settings-daemon` 的 media-keys 插件**
  （`usr/lib/aarch64-linux-gnu/ukui-settings-daemon/libmedia-keys.so`）：`MediaKeyAction::doPowerKeyAction()`
  读 `button-power` 的 **enum 下标**再调 `doSessionAction(PowerType)`。`PowerType`（`media-type.h`）只定义了
  `{POWER_SUSPEND=1, POWER_SHUTDOWN=2, POWER_HIBERNATE=3, POWER_INTER_ACTIVE=4}` —— **没有 0**，于是
  `blank`（enum 0）在 `doSessionAction` 的 switch 里**无 case**、落到 `executeCommand("ukui-session-tools", {})`
  → 只弹「询问」会话菜单（这就是"选了关闭显示器、按键还是询问"的原因）。
- **修法**（对**已编译**文件打补丁，无需重编；源码等价补丁见 `docs/patches/`）：
  1. **`libpower.so`**：下拉追加 `tr("Blank")`/`"blank"`。因 openKylin 归档的 -dev 包与设备已装的**新版 X/GL 库版本冲突**
     （`libxrandr2` 1.5.4 vs 1.5.2 等）、**装不上构建依赖**，改为**复用本机永不执行的 hibernate 分支**（sheng 无休眠，
     `/sys/power/state == "freeze mem"`）：该分支跳转改 NOP、QVariant 数据 `"hibernate"→"blank"`、标签
     `tr("Hibernate")→tr("Blank")`（`Blank`→「关闭显示器」的中文翻译已存在）。3 处各 4 字节。
  2. **`libmedia-keys.so`**：`doSessionAction` 里那个程序字符串 `"ukui-session-tools"`（**全文件仅此一处引用**）改成
     `"sheng-pwrkey"`（等长、零填充）。控制中心/面板用各自副本，不受影响。
  3. 覆盖层落两个脚本：`/usr/bin/sheng-pwrkey`（收到**无参**调用且 `button-power=blank` → 调 `sheng-screen-toggle`；
     否则 `exec ukui-session-tools "$@"` 原样透传 suspend/shutdown/hibernate/interactive）、
     `/usr/local/bin/sheng-screen-toggle`（用状态文件 `/run/user/<uid>/sheng-panel-off` 切换 `kscreen-doctor -d off/on`）。
     ⚠️ **关屏必须等电源键"松开"再 `-d off`**：`kscreen-doctor -d off` 是合成器级 DPMS，`kylin-wlcom` 会在
     **触发它的那次按键输入**上立刻"醒来"重新点亮 —— 立即关屏会瞬间又亮（实测"黑一下马上亮"）。**不能用固定延时**
     （延时要 ≥ 用户按住时长，按得越久越慢，没法两全）。故 `sheng-screen-toggle` 读 `pmic_pwrkey` 的 evdev
     （`luser∈input` 组，`/dev/input/event0`；`EVIOCGKEY` 查当前是否按住、是则等 `KEY_POWER` 松开，最多 3s），
     **你松手的那一刻就关屏**。下次按键时状态文件存在 → 合成器自己唤醒 + 我们补一发 `-d on`（空操作）→ 亮屏并删状态文件。
- ⚠️ **打 `libmedia-keys.so` 补丁后需重启 `ukui-settings-daemon`**（它**没有 systemd 用户单元**，是会话 autostart：
  `pkill -f /usr/bin/ukui-settings-daemon` 后用会话环境重启）才生效。
- ⚠️ **与自动转屏互斥**：`set_rotation`（`com.kylin.statusmanager.interface`）会做一次**输出重配置**，`kylin-wlcom` 会把它当成"活动"而把刚熄的屏**又点亮**（手持、非平放时才会转屏，故只在按电源键熄屏时撞见）。修法：`sheng-autorotate` 在**面板已熄**时**跳过转屏**，屏亮后若朝向变了再补转（见 `system_files_openkylin/usr/local/bin/sheng-autorotate`）。
  - 判据用**两个**：状态文件 `/run/user/<uid>/sheng-panel-off`（`sheng-screen-toggle` 在 `close-activation-enabled=false` 分支建的那个）**或**真实 DPMS 状态（`/sys/class/drm/*-DSI-1/dpms == "off"` 或 `/sys/class/backlight/*/bl_power != 0`，与 `sheng-fp-unlock-wake` 同一套读法）。
  - ⚠️ **回归教训（2026-10 复现）**：只查状态文件**不够**。当「唤醒屏幕时需要密码」(`org.ukui.screensaver close-activation-enabled`，**息屏指纹解锁功能正需要它**) 为真时，`sheng-screen-toggle` 走 `ukui-screensaver-command --lock` 分支、**不再写状态文件** → 只查文件的旧守卫失效 → 转屏又把屏点亮（症状回归，实测 `kscreen-doctor -d off` 后 `set_rotation` 立刻把 `dpms` 从 Off 翻回 On）。DPMS 判据对**所有**熄屏路径都成立、且熄屏时由合成器置位、亮屏时自动清位，不依赖状态文件。注意 `org.ukui.ScreenSaver.GetBlankState` **不**可作判据（它不反映 `kscreen-doctor` 的 DPMS）。
- **（顺带）"到点自动关屏"也要锁屏**：`ukui-powermanagement` 的 IdleWatcher 在到点关屏时本应执行 `ukui-screensaver-command -b idle`（锁屏），但它写成 `QProcess process; process.start("ukui-screensaver-command -b idle")` —— Qt 的 `QProcess::start(program)` **不按空格切分**（与 `system()` 不同），于是去执行一个**名字含空格**的"可执行文件"→ `FailedToStart` → **到点关屏从不锁屏**（只有电源键那条会锁）。构建步骤 6g 的 PART 3 把该程序串（`ukui-powermanagement` 内，唯一一处）改成无空格路径 `/usr/local/bin/sheng-idle-lock`；该包装脚本在 `close-activation-enabled` 为真时执行 `ukui-screensaver-command --lock`（**立即锁**；`-b idle` 是"延时锁屏"，刚熄灭马上点亮会免密）。落地文件 `system_files_openkylin/usr/local/bin/sheng-idle-lock`。⚠️ 打此补丁后需重启 `ukui-powermanagement`（会话 autostart；运行中改会 `ETXTBSY`，需先停掉、或改副本再 `mv`）。源码等价补丁见 `docs/patches/ukui-power-manager-idle-lock-screensaver.patch`。
- 验证（实机）：下拉出现「关闭显示器」；选中后 `gsettings get … button-power` = `blank`、framework 属性 = `blank`；
  触发媒体键的 `POWER_OFF_KEY`（`busctl --user call org.ukui.SettingsDaemon /org/ukui/SettingsDaemon/MediaKeys
  org.ukui.SettingsDaemon.MediaKeys externalDoActionWithName ss POWER_OFF_KEY ''`）→ 屏灭（状态文件出现），再触发 → 屏亮。

### openKylin 3.0：指纹（FPC1553 / 电源键指纹）

构建步骤 **5f（开关 `FINGERPRINT_ENV`，默认开）** 把**指纹**做成开箱即用：控制中心/锁屏能录入、**按住即解锁**、**点休眠不被指纹打断**。这条链既不是 openKylin 自带、也不是上游 Debian 的现成方案 —— openKylin 的图形登录/锁屏**只认 Kylin `biometric-auth`**（不走 fprintd），而它的多设备驱动发现是 **USB** 的、看不到非 USB 的 FPC1553。本仓库在真机上逐条打通：

- **内核侧**：只需 `fpc1553` 驱动 + `/dev/tee0`；真正干活的是签名 TA `fpcsheng`（配 QTEE 5.2 / `qcomtee`）。
- **用户态栈**：上游 `ianchb/xiaomi-sheng-fingerprint`（纯用户态）—— `qteesupplicant`（MinkIPC/Mink 运行时）+ `libfpc1553-qtee.so`（FPC 协议后端）+ 一颗**含 fpc1553 驱动的私有 libfprint** + qtee-listeners + systemd 单元 + udev 规则。构建从 GitHub release 取 `xiaomi-sheng-fingerprint_0.1.4_arm64.deb`，用 `dpkg-deb --fsys-tarfile` 解开塞入（**不装 fprintd** —— Kylin 原生路径用不上）。
- **Kylin 驱动接线**：Kylin `biometric-auth` 的多设备驱动（`goodixmoc.so` 等）其实是同一个 demo 模板，按**烤在 .so 里的驱动名**过滤 libfprint 设备。做法：`cp goodixmoc.so fpc1553.so` 并把偏移 `0x8430` 的 `goodixmoc` 改成 `fpc1553`；`biometric-drivers.conf` 追加 `[fpc1553]`；服务 drop-in `FP_FPC1553=1` + `LD_LIBRARY_PATH=/usr/lib/xiaomi-sheng-fingerprint`（让驱动用**兄弟目录那颗含 fpc1553 的私有 libfprint**）。
- **自研补丁**（预编译二进制在 `fingerprint_payload/`，构建时覆盖；第 2 条可用 `tools/sheng-fp-thermal-off.sh` 复现/重打）：
  1. `libfprint-2.so.2.0.0` —— 改 fpc1553 驱动 `wait_for_finger_lift`：验证/识别**匹配到即上报**（不再等手指抬起）但**保留芯片 deep-sleep** → **按住即解锁**（原版必须松手才结算）。
  2. `libfprint-2.so.2.0.0`（同一颗 so，另有 **2 字节**补丁）—— 关掉 libfprint 的**温度模型**（等价源码 `dev_class->temp_hot_seconds = -1`；上游 libfprint 里所有 match-on-chip 驱动 goodixmoc/fpcmoc/elanmoc/synaptics/realtek/focaltech **都显式关它**，本移植漏了 → 落回默认 **180 秒**）。**不关的后果（真机实测）**：息屏锁屏后，锁屏对话框在面板全黑时**每 30 秒重挂一次 Identify、永不停止**（`irq after reset` 每轮一次硬件复位）；累计 180 秒即判 HOT → 驱动返回 `FP_DEVICE_ERROR_TOO_HOT` → 框架报 `Device disabled to prevent overheating.` → 此后每次识别**瞬时失败**，而锁屏对话框把瞬时错误当成连续失败**并立即重试** → **几秒内烧完 `MaxFailedTimes=5`**，用户点亮屏幕即见「指纹失败，5 次机会全用完」。本驱动的空闲等待是 `poll()` + `fingerdown_wait` 的 **IRQ 事件**（不是忙轮询/连续拍照），所以这个估算模型对它过度保守，关掉是安全的。
  3. `fpc1553.ko.zst` —— 去掉内核模块里**无条件**的 `irq_set_irq_wake`（指纹 IRQ 不再是唤醒源）→ **点休眠不再 ~1.8 秒自唤醒**。

> ⚠️ **可维护性**：升级**内核**要重编 `fpc1553.ko`（vermagic 须精确匹配注入内核）；升级 `xiaomi-sheng-fingerprint` **包**会覆盖私有 `libfprint`。
> ⚠️ **别删单个指纹模板**：`biometric-auth-client clean -i <单个>` 会让 Kylin 库与 TA 库失步 → 之后验证一直失败且**还原文件也救不回**。要改就"清空全部 + 重录一个"（`clean -i -1`）。
> 💡 **速度**：比对耗时**正比模板数** —— 只保留 **1 个**（~1s；2 个约 3s）。设备 ID 用 `biometric-auth-client get-device-list` 查。

**息屏指纹的完整行为（手机式：息屏时指纹一碰 → 解锁并亮屏）**

- 息屏（面板 DPMS Off）期间锁屏对话框**一直武装着指纹** —— 这是要保留的，正是"息屏直接按手指解锁"的前提。
- 指纹**匹配成功**时对话框**自己会解锁会话**（stock 行为）；但面板仍是 DPMS Off，用户看不到任何反馈，还得再按一次电源键。原因：**指纹触摸不是输入事件**，`kylin-wlcom` 只对触摸/电源键做 unblank，不会因为指纹而唤醒面板。
- 补法：用户级守护进程 **`sheng-fp-unlock-wake`**（构建步骤 **6a-9**，开关 `FP_UNLOCK_WAKE_ENV`）。它监听会话总线 `org.ukui.ScreenSaver` 的 **`unlock` 信号**（并用 `GetLockState` 每秒轮询兜底），一旦发现「会话已解锁 **且** 内屏黑着」（`dpms==off` 或 `bl_power!=0`，两个指标互为冗余）就 `kscreen-doctor -d on`；**指纹不匹配时不动作**，保持黑屏（与手机一致）。日志在 `~/.log/sheng-fp-unlock-wake.log`。
- 实机验证：息屏后碰手指 → 屏幕自动亮起进桌面，守护进程日志 `panel is OFF and session unlocked (unlock signal) -> turning panel on`（信号路径生效，非轮询兜底）。
- ⚠ 该守护进程**只负责点亮**；"匹配→解锁"是锁屏对话框自己的事。

**顺带修掉的一个系统问题**：镜像里的 `/dev/null` 可能是 `0755`（应为 `0666`，真机上实测如此）→ 普通用户写 `/dev/null` 直接失败，`cmd >/dev/null 2>&1` 这类重定向会让**整条命令被静默跳过**（本仓库多个 `sheng-*` 脚本都依赖该写法，例如 `sheng-screen-toggle` 里的关屏调用）。构建步骤 **6a-10** 把它纠正为 `0666`。

### openKylin 3.0：文件管理器首次打开卡 ~10s + "peony程序无响应"

构建步骤 **6a-6（开关 `PEONY_IDM_FIX_ENV`，默认跟随 `REMOVE_AI`）**。

- **症状**：开机后**首次**点桌面「计算机」打开文件管理(peony) 卡 ~10s，随后合成器（`kylin-wlcom`）弹
  「peony程序无响应（进程号XXX）是否强制关闭应用」。冷启动 10.6s、二次起 0.4s（只"首次"慢）。
- **根因**：peony 首启会 D-Bus 激活 `com.peony.idm.service` → 用户服务
  `peony-intelligent-data-management-service`（「智能空间/AI 分组」）。该服务连 Kylin AI 后端 socket
  `/tmp/.kylin-ai-business-unix/1000/KnowledgeBaseService.sock` **每秒重试、10s 后放弃**（`kb_session_init`
  失败）；peony **同步等**它就绪 → 主线程冻结 10s → wlcom 记 `peony view is not responding`。
  （gdb 全线程栈显示主线程其实空在 `QCoreApplication::exec()→poll()`，**不是死锁**。）
- **修法**：给 luser 建掩码软链
  `~/.config/systemd/user/peony-intelligent-data-management-service.service -> /dev/null`（等价
  `systemctl --user mask`；构建期没有用户 session，直接建软链）。激活立即失败 → peony 不再等 → **首开 10.4s→0.2s**。
- **⚠️ 与 `REMOVE_AI` 耦合**：该服务**只在 kylin-ai 后端缺失**时才会白等 10s；后端在时「智能空间」正常。
  故 `PEONY_IDM_FIX_ENV` **默认跟随 `REMOVE_AI`**（`if is_true "$REMOVE_AI"`）：`REMOVE_AI=1`（剥离 AI）→ 掩码；
  `REMOVE_AI=0`（保留 AI）→ 不掩码。**别只翻一个**：把 AI 加回来却仍掩码 IDM → 智能空间依然起不来。
- **"智能空间"不靠额外开关**：侧栏 `idm://` 根项（`IntelligentVFSInfoPlugin`，`displayName=Intelligent Space`）
  和工具栏「新建」下拉项都**无条件添加、不受 `isAiAvailable()` 门控**（后者只用于搜索框渐变边框）——AI 在则列表
  有内容，AI 不在则空壳。故恢复 AI 后（重建 `REMOVE_AI=0`，或设备上 `systemctl --user unmask
  peony-intelligent-data-management-service.service`）**无需其他操作**即自动恢复；反之 AI 不在时**不要**unmask（会把 10s 卡顿带回来）。
- 实机（无 AI 的设备）：AI 后端包（`kyai-data-management-service`/`kylin-ai-knowledge-base-service`/
  `kylin-ai-runtime` 等）dpkg 状态为 `install ok config-files`（已卸载只剩配置），`/tmp/.kylin-ai-business-unix`
  不存在 → 属 `REMOVE_AI=1` 建的，"无 AI + 掩码"即正确状态。

### openKylin 3.0：文件管理器手指点不开文件夹（可滚动目录）—— 修 ukui 触摸手势

构建步骤 **6a-7（开关 `GESTURE_SCROLL_FIX_ENV`，默认开）**，打库 `tools/sheng-gesture-scroll-fix.sh`。

- **症状**：文件管理器里**鼠标**双击能打开文件夹，但**手指**在**条目多、需要滚动的目录**里怎么点都打不开；放得下、不滚动的目录正常（条目越少越容易开）。**平板模式**下能开（它会把窗口自动全屏 → 一行放得下更多、不滚动）。
- **根因**：ukui 的手势插件 **`libqt5-gesture-extensions`**（由 ukui Qt 样式对每个 `QAbstractScrollArea` 自动 `registerWidget`）对滚动区 viewport 调 `QScroller::grabGesture(viewport, QScroller::TouchGesture)`；而 `grabGesture(TouchGesture)` 会顺带 `viewport->setAttribute(Qt::WA_AcceptTouchEvents)` —— **部件一旦接收触摸事件，Qt 就不再把它合成鼠标事件**。peony 靠**鼠标双击**打开 → 可滚动目录里"没有鼠标事件"→ 手指点不开。（放得下不滚动的目录 QScroller 不介入，仍走 Qt 合成 → 正常；鼠标不受影响。）该插件设的 `QScrollerProperties`（`MaximumClickThroughVelocity=0`）**无关**（实测改它无效）。
- **修法**：把手势类型 **`TouchGesture`(0) → `LeftMouseButtonGesture`(1)**。于是不再设 `WA_AcceptTouchEvents` → 触摸重新被合成为鼠标（**双击成立、能打开**），而 QScroller 改为抓"鼠标拖拽 flick" → **一指拖动仍能滚动**。**两全**。
- **实现**：就地打 `.so` 字节补丁（无需源码重编）。`SlideGesture::registerWidget` 里唯一的 8 字节序列 `mov w1,#0 ; mov x20,x0`（`01 00 80 52 f4 03 00 aa`）→ `mov w1,#1 ; …`（`21 00 80 52 f4 03 00 aa`）；按**字节模式**定位（不硬编码偏移）、幂等。等价源码：`qt5-gesture-extensions/gesture-extensions/slide-gesture.cpp` 的 `registerWidget()` 用 `QScroller::LeftMouseButtonGesture`。
- ⚠️ 排查备忘：`QT_DBL_TAP_DIST`/`QT_DBL_CLICK_DIST`（=30，由 `libqt5-gesture-extensions1` 装的 `/etc/X11/Xsession.d/101qt-dist-threshold`）与"双击间隔(`org.ukui.peripherals-mouse double-click`)"**都不是**原因；`qt5-styles-ukui` 里的 `GestureHelper` 是**死代码**（`new` 被注释），也不是。

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
| **openKylin3：自动亮度开关打开但屏幕不随环境光变** | 自带 `libauto-brightness.so` 能读光感，但经内部 `BrightThread` 施加亮度在本机 Wayland/kylin-wlcom 上无效（开灯/关灯/`debug-lux` 扫值都不变）→ 改用自带的 `sheng-autobrightness`（`ssccli --sensor light` → `setPrimaryBrightness`，见「openKylin 3.0：自动亮度」） |
| **openKylin3：转屏 / 重启把屏幕亮度重置成最亮** | `ukui-settings-daemon` 只按 `/sys/class/backlight/*/brightness` 节点是否存在就认定“硬件背光可调”，把唯一内屏当笔记本内屏，**每次输出重配置（转屏）都把合成器亮度拉满到 100**；本平板 upm 其实调不了该节点（`CanSetBrightness=false`）。打补丁让 `UsdBaseClass::upmSupportAdjustBrightness()` 返回 false（`tools/sheng-usd-brightness-fix.sh`，步骤 6c；等价源码补丁见 `docs/patches/`）→ 改由合成器 gamma-manager 管亮度（值存 `/etc/ukui/usd/globalconf.ini [color]`），转屏/开机即保留，且无闪屏。见「openKylin 3.0：屏幕亮度 = 真实背光」 |
| **openKylin3：调亮度后暗场景发灰（合成器软件亮度「滤镜」）** | gamma-manager 把用户值经 `GmHelper::normalizeBrightness` 映射后下发合成器 `com.kylin.Wlcom.Output.SetBrightness`，合成器对像素做乘法（`color *= brightness`）= 滤镜，压暗部。构建把 `normalizeBrightness`/`denormalizeBrightness` 钉成**常量 100**（`mov w0,#100; ret`，步骤 6c），亮度改由**真实面板背光**承担：`sheng-panel-brightness` 引擎（步骤 6a-5）监视 `globalconf.ini [color]` → 写 `/sys/class/backlight/ktz8866-backlight`。旧的 `sheng-backlight-fixed`（钉死背光）已移除。见「openKylin 3.0：屏幕亮度 = 真实背光」 |
| **openKylin3：「设置→显示器」亮度滑块拖动无效** | `libdisplay.so` 的 `Widget::isSetGammaBrightness()` 本机恒 false → 滑块只写 gsettings `brightness-ac`（upm 硬件路），而 upm 驱动不了 ktz8866（`RegulateBrightness` 返回 `"no effective node"`）→ 无效；侧栏走 `setPrimaryBrightness`（gamma）故正常。构建装 `sheng-brightness-ac-bridge`（步骤 6a-3）监听 `brightness-ac` → 转发 `setPrimaryBrightness`。见「openKylin 3.0：「设置 → 显示器」亮度滑块」 |
| **openKylin3：转屏（横竖屏）时亮度被顶到很亮 / 100%** | usd 在**输出重配置**时会重新施加**最近被写过**的 gsettings `brightness-ac`，而本机该施加路径损坏：把值**放大**（实测 51→78、73→99、59→92→100）。`brightness-ac` 是 usd 的**输入键**，写它即"上膛"；上膛源是本仓库桥接的反向同步（真机抓到唯一一次 dconf 写入即它写的 `brightness-ac=92.0`）。修法：桥接**不再回写** `brightness-ac`（`SHENG_BRIDGE_MIRROR=1` 才开）；`sheng-autobrightness` 识别输出重配置并拒绝把随之而来的跳变学成"用户偏置"，且立即纠正。见「转屏时亮度被顶到 100%」 |
| **openKylin3：缩放屏幕最大只到 225%（选不到 250% / 275%）** | 同一 `libdisplay.so` 的 `OutputConfig::initScaleItem()` 用**硬编码分辨率阈值**加档：`250%` 只在当前分辨率宽度 **>3072**、`275%` 只在 **>3840** 时才 `addItem`，而本机面板原生 **3048×2032**（3048 不大于 3072/3840）→ 下拉框最大只到 225%（225% 的闸门是 >2560，3048 满足）。构建把 250%/275% 闸门 `cmp w0,#0xc00(3072)` / `#0xf00(3840)` 都改成 `#0xa00(2560)`（`install_display_scale`，步骤 6a-4；两种闸门各 3 处全替换）。合成器(wlcom)本身支持 2.5/2.75 分数缩放（实测 `kscreen-doctor output.DSI-1.scale.2.5` 生效、几何随之变化） |
| **openKylin3：休眠时"黑屏但背光还亮一会"** | logind 先发 `PrepareForSleep(true)`（合成器立即关输出=黑屏，不动背光），再等一批 delay inhibitor 放行才真正 suspend；背光要等内核 suspend 才被 DSI 面板/`ktz8866` 驱动切断。构建装系统级 `sheng-suspend-backlight`（步骤 6e）监听 `PrepareForSleep`：`true`→背光写 0，`false`→还原。见「休眠时立即关背光」 |
| **openKylin3：息屏后电源键"要等一会才响应"** | logind 等 `kylin-process-manager` 的 sleep delay 锁，硬等满 `InhibitDelayMaxSec`（默认 5s）才强制挂起；这 5s 屏幕黑但系统没睡，电源键无效。构建步骤 6f 装 logind drop-in 设 `InhibitDelayMaxSec=1`。见「休眠时立即关背光」 |
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
| **openKylin3：指纹（控制中心/锁屏）看不到设备 / 必须松手才解锁** | openKylin 图形登录/锁屏只认 Kylin `biometric-auth`（USB 发现看不到非 USB 的 FPC1553）。构建：`goodixmoc.so`→`fpc1553.so`（改烤死的驱动名 @0x8430）+ 追加 `[fpc1553]` 段 + 服务 drop-in（FP_FPC1553=1 + LD_LIBRARY_PATH）+ 覆盖"匹配即上报"的私有 `libfprint`（步骤 5f，见「openKylin 3.0：指纹」） |
| **openKylin3：点休眠 ~1.8 秒自动唤醒** | `fpc1553` 内核模块在 `fpc1553_prepare` 里**无条件** `irq_set_irq_wake(1)` → 指纹 IRQ 成唤醒源（`/sys/kernel/irq/N/wakeup` 只读，用户态关不掉）。构建覆盖**去掉该调用**的 `fpc1553.ko`（步骤 5f） |
| **openKylin3：系统更新失败**（装通用内核时报错） | openKylin 是 ostree 部署；`ostree` 包把 `/etc/kernel/{postinst,postrm}.d/zz-ostree-update` 当内核钩子，在**非 ostree**（摊平 ext4）系统上报 `system not ostree type` 并 **exit 1** → 通用内核 `linux-image-*-generic` 的 postinst 失败 → 整个更新失败。构建把该钩子改成 **no-op**（步骤 5g） |
| **openKylin3：更新界面显示 `openKylin No section:'SYSTEM'`** | 镜像自带的 `/usr/lib/system-info/kylin-system-version.conf` 是 **0 字节** → `kylin-system-updater` 取 `[SYSTEM]` 段失败（`NoSectionError`）→ 界面把异常串当版本号打印。构建补 `[SYSTEM]` 段（步骤 5g） |
| **openKylin3：每次更新都换通用内核**（~100MB initrd，对 sheng 无用） | 镜像带 `linux-generic`；对 sheng 无意义（引导的是 sheng mainline 内核）。构建 `apt-mark hold linux-generic linux-image-generic linux-headers-generic`（步骤 5g，best-effort） |
| **openKylin3：重启后双击输入框打不开键盘**（偶发；且此前完全不可观测） | fcitx5 有 autostart 与 **D-Bus 按需激活**两条启动路径，`org.fcitx.Fcitx5` 总线名只能被一方抢到，输的一方退出（`Unable to request dbus name. Is there another fcitx already running?`）。原先只有 autostart 那条带 `LD_PRELOAD=sheng-osk-gate.so`，而登录时 `kylin-virtual-keyboard` 先来要名字、**常常是 D-Bus 激活赢** → fcitx5 裸启动 → 垫片没进 → 没人写 `sheng-osk-textactive` → 守护 `sheng-osk-tap.py` 把每次双击都正确识别后又 `skip (no text field focused)`。构建步骤 6a-8 现在让**两条路径都 exec 包装脚本 `fcitx5-sheng`**，并把守护 stderr 落到 `/tmp/osk-tap/tap.log`（`sheng-osk-tap-run`）。见「openKylin 3.0：屏幕键盘」→「启动顺序陷阱」 |
| **openKylin3：屏幕键盘弹出偏慢**（每次弹出都重建视图）（**已试后撤销**） | `kylin-virtual-keyboard` 的 QML 视图按 gsettings `preload-view-enabled` 决定复用还是销毁，上游默认 **false** → 每次弹出都重建 `QQuickView` + 重载主题 + 编译着色器（源码 `virtualkeyboardview.cpp` 的 `initView()`/`destroyView()`）。真机实测 `show→可见` 0.43/0.53/0.51s（false）→ 0.34/0.36/0.32/0.31s（true，约快 38%）；剩余 ~300ms 是合成器上屏（DSI-1, scale 2.5），关动画无效。**曾装 `99-sheng-osk.gschema.override` 打开该键，但 true 会命中下一行的转屏缺陷，两者连锁问题多于收益 → 已撤销**，现在保持上游默认（慢一点但行为干净） |
| **openKylin3：转屏后屏幕键盘尺寸不自适应**（「键盘收起时转屏、再打开」尺寸不对；「键盘开着时转屏」却正常）（**只诊断，未修**） | 几何是**实时**算的（`geometrymanager.cpp:54` → `expansionsgeometrymanager.cpp:24` → `screenwatcher.cpp:39` 直接读 `QScreen::geometry()`），转屏事件也**正常发出**（`screenwatcher.cpp:241`）。问题在**施加**环节被可见性闸门挡住：`virtualkeyboardmanager.cpp:274` 与 `virtualkeyboardview.cpp:102` 都有 `if (!isVisible()) return;`，而唯一无条件施加几何的 `virtualkeyboardview.cpp:196 view_->setGeometry(calculateInitialGeometry())` 在 `:150` 因 `preloadViewEnabled` **提前 return 而再不执行** → 窗口尺寸冻结在视图创建那一刻。**注意：该症状只在 `preload-view-enabled=true` 时出现**；上游默认 `false` 时每次弹出销毁+重建视图、重走 `:196`，所以「收起转屏再打开」是**自适应的**。曾用运行时守护 `sheng-osk-rotate`（转屏时重启键盘重建几何）让两者并存，但引出「键盘可见时被误杀/限流锁死/重建后不可用窗口」等问题，**已全部撤销**。真正的上游级修法是一行补丁：视图复用时若屏幕算出的尺寸与窗口现有尺寸不同则重设几何（只比尺寸以保留滑入动画）——未编进镜像（设备无 `qtbase5-dev`） |
| **openKylin3：屏幕键盘 SIGSEGV 偶发崩溃**（上游 bug，未修） | `coredumpctl` 里有 20+ 次 `kylin-virtual-keyboard` SIGSEGV，栈顶是 `QWindow::screen()` 空指针（`← QTimer::timeout`），对应 `waylandworkspaceadjuster.cpp:57` 的 `surfaceWindow_->screen()`：`screenwatcher` 的旋转/几何变更定时器回调时 `QWindow` 已销毁。同文件 `:34`/`:54` 都有判空，唯独 `:57` 漏了。属上游 openKylin 问题（[issues](https://gitee.com/openkylin/kylin-virtual-keyboard/issues)），设备无 Qt5 dev 包无法本地编译验证 |
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
| **传感器**（加速度计/陀螺/光感/霍尔） | 🟡 挂在 ADSP **SSC** 后面，走 `libssc`（QMI over QRTR）。**加速度计已可用并用于 openKylin3 自动转屏**（见「openKylin 3.0：自动转屏」）；需装 `protection-domain-mapper` + enable `adsprpcd`。`iio-sensor-proxy` 3.8 对本机固件仍会 core dump（缺 `measurement_id`），故用 `sheng-autorotate` 直连 `ssccli`；陀螺/磁力/距也能 `ssccli` 读到，**光感已用于 openKylin3 自动亮度**（见「openKylin 3.0：自动亮度」） |
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

### openKylin 3.0：屏幕键盘「双击输入框弹出」（停用一聚焦就自动弹）

屏幕键盘是 **`kylin-virtual-keyboard`**（由 **fcitx5** 驱动）。它本来**只要文本输入框获得焦点就自动弹**
（走 `fcitx::UserInterfaceManager::showVirtualKeyboard()`，受 `virtualKeyboardAutoShow` 默认 true 控制）
——**界面打开自动聚焦、微信切好友**时都会弹（用户没点输入框）。改成：**只有双击、且当前有输入框聚焦时才弹**。

**做法（构建步骤 6a-8，开关 `OSK_TAP_ENV`，默认开）**：

- **fcitx5 侧垫片 `sheng-osk-gate.so`**（`LD_PRELOAD` 进 fcitx5，源码 `tools/sheng-osk-gate.c`，**预编译 arm64**）：
  - 把 `_ZNK5fcitx20UserInterfaceManager19showVirtualKeyboardEv` 空实现 → **拦掉自动弹出**；
  - 同时用它的 show/hide 请求维护「当前是否有输入框聚焦」：`showVirtualKeyboard`→`$XDG_RUNTIME_DIR/sheng-osk-textactive=1`，
    `hideVirtualKeyboard`（文本框失焦）→`=0`。
  - （反汇编确认这两个调用都走 `@plt`，可被 preload 拦。）
- **守护 `sheng-osk-tap.py`**（`/usr/local/bin/`，**以用户跑**）：只读触摸屏 `/dev/input/event3`
  （`NVTCapacitiveTouchScreen`, MT-B，**不抢事件**）识别**双击**（两次干净单击，各 down..up ≤0.35s、位移 ≤260 单位；
  两击间隔 ≤0.45s、距离 ≤350 单位）；双击时**仅当** `sheng-osk-textactive=1` 且键盘没显示 → 调
  `org.fcitx.Fcitx5 /virtualkeyboard org.fcitx.Fcitx.VirtualKeyboard1 ShowVirtualKeyboard` 弹出。
- **自启：`fcitx5` 有两条启动路径，两条都必须带垫片** ⚠️（见下面「启动顺序陷阱」）。
  现在两条都 `exec` 同一个包装脚本 `/usr/local/bin/fcitx5-sheng`（内含 `LD_PRELOAD`）：
  `/etc/xdg/autostart/fcitx5.desktop` 与 `/usr/share/dbus-1/services/org.fcitx.Fcitx5.service` 的
  `Exec=` **都**是 `/usr/local/bin/fcitx5-sheng`；新增
  `/etc/xdg/autostart/sheng-osk-tap.desktop` → `/usr/local/bin/sheng-osk-tap-run`（包装，落日志）拉起守护。
- **本目录只做这一件事**：双击输入框弹出键盘（外加停用"一聚焦就自动弹"）。
  曾试验并已**全部撤销**的两项（问题多于收益，用户决定回到原始状态）：
  1. **键盘视图预加载**（gsettings `preload-view-enabled=true` + 系统级
     `99-sheng-osk.gschema.override`）：让展开快约 38%（0.51→0.34s），但视图复用后
     **窗口尺寸冻结在创建那一刻** → 「收起键盘→转屏→再打开」不自适应。
  2. **转屏守护 `sheng-osk-rotate`**：1Hz 读 `com.kylin.statusmanager.interface.get_current_rotation`，
     只在「方向变了且键盘隐藏」时重启键盘进程以重建几何，用来兜住上面那条。
     它确实能让两者并存，但引入了多轮新问题（曾误杀可见键盘→"转屏后键盘自动收起"；
     限流参数过紧→"转屏后一段时间不再重建"；以及重建后键盘有"启动中不可用"的窗口）。
     守护文件、unit、上游补丁、gschema override 均已从构建移除，应从仓库删除。
     顺带记录：键盘本身有已知崩溃（`screenwatcher` 旋转回调里 `QWindow::screen()` 空指针，
     多发生在**转屏瞬间**），所以「方向变化 + 进程消失」会撞在一起，任何重建方案都得先解决这个。
- 落地文件：`system_files_openkylin/usr/local/lib/sheng-osk-gate.so`、
  `system_files_openkylin/usr/local/bin/sheng-osk-tap.py`、
  `system_files_openkylin/usr/local/bin/{fcitx5-sheng,sheng-osk-tap-run}`、
  `system_files_openkylin/usr/share/dbus-1/services/org.fcitx.Fcitx5.service`、
  `system_files_openkylin/etc/xdg/autostart/{fcitx5.desktop,sheng-osk-tap.desktop}`、
  `tools/sheng-osk-gate.c`。

> **效果**：界面打开自动聚焦 / 微信切好友 → **不弹**（单击好友、点按钮、滚动、双击文件夹都不弹，
> 因为那些时刻 `sheng-osk-textactive=0`）；**双击输入框 → 弹**。

#### 启动顺序陷阱：垫片「有时在、有时不在」（真机踩过，2026-10-09 定位）

**症状**：重启后双击输入框**没反应**，且表现为**偶发**——有的开机正常、有的必坏；此前一直查不出，
因为守护 stderr 被丢进 `/dev/null`，整个链路不可观测。

**根因**：`fcitx5` 有两条启动路径，而 `org.fcitx.Fcitx5` 这个总线名**只能被一方抢到**，输的一方
直接退出并卸载 addon（日志表现为
`addonloader.cpp: Failed to create addon: dbus Unable to request dbus name. Is there another fcitx already running?`）：

1. `/etc/xdg/autostart/fcitx5.desktop` → systemd `app-fcitx5@autostart.service`
2. `/usr/share/dbus-1/services/org.fcitx.Fcitx5.service` → **D-Bus 按需激活**。登录时
   `kylin-virtual-keyboard` 会先来要这个名字，所以**常常是这条赢**。

原先**只有 (1) 带 `LD_PRELOAD`**。于是 (2) 赢的那些开机里 fcitx5 是**裸启动**的：垫片没进 →
没人写 `sheng-osk-textactive`（**文件根本不存在**）→ 守护把每次双击都正确识别后又按设计
`skip (no text field focused)` → **键盘根本弹不出来**。

**修法**：两条路径都 `exec` 包装脚本 `fcitx5-sheng`（内含 `LD_PRELOAD`），谁先赢都带垫片。
注意 `Exec=env LD_PRELOAD=… /usr/bin/fcitx5` **不能**直接写进 D-Bus 激活文件（那会变成去执行名为
`env` 的程序）；desktop 文件里也不能把 shell 逻辑塞进 `Exec=`（desktop-entry(5) 不允许未引用的
`;` `$` `&` `>` 和 `%` 字段码，`desktop-file-validate` 会报错），所以逻辑必须落在包装脚本里。

**教训（排查手段）**：守护 stderr 必须落盘。现在由 `sheng-osk-tap-run` 写到 `/tmp/osk-tap/tap.log`
（含 `--- session start ---` 与每次 `tap` / `double-tap … -> show|skip(原因)`），
一眼就能区分「双击没识别」和「识别了但被 skip」。

> **排查/调参**：垫片把 show/hide 记到 `$XDG_RUNTIME_DIR/sheng-osk-req.log`，标记写 `…/sheng-osk-textactive`
> （该文件在 `/run/user/1000/`，**会话结束即清空**，所以每次开机都从 0 开始 —— 这是设计，不是 bug）；
> 守护把每次点击/双击写到 `/tmp/osk-tap/tap.log`。阈值在 `sheng-osk-tap.py` 顶部
> （触摸单位 ≈0.1px，所以 `DBL_TAP_DIST=350` 实际只有 **35px**、`MAX_TAP_MOVE=260` 只有 **26px**；
> 觉得"手抖就不认"就调大）。
> **撤销**：还原 `/etc/xdg/autostart/fcitx5.desktop`（备份 `fcitx5.desktop.orig.bak`）、还原
> `/usr/share/dbus-1/services/org.fcitx.Fcitx5.service`（设备上手工改的备份是
> `…service.pre-gate.bak`）、删 `sheng-osk-tap.desktop`、删
> `fcitx5-sheng` / `sheng-osk-tap-run` / `sheng-osk-tap.py` / `sheng-osk-gate.so`、重启会话。

> 本目录**不含**键盘弹出提速与转屏自适应：曾做过「视图预加载 + 转屏守护」两项，实测确实能让
> 展开快约 38% 且「收起转屏再打开」跟随尺寸，但连锁引出的问题（键盘可见转屏被误杀、限流锁死
> 正常转屏、重建后有一段"启动中不可用"窗口）多于收益，已按决定全部撤销。若将来要重做，
> 优先走**上游一行补丁**（视图复用时按当前屏幕重设几何）而不是运行时守护。

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
