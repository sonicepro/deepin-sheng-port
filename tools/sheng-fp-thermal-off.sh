#!/bin/sh
# =============================================================================
# sheng-fp-thermal-off.sh — 关掉私有 libfprint 里的「温度模型」
# =============================================================================
# 背景（真机实测的根因）：
#   openKylin 锁屏对话框在息屏期间会**无限重挂**指纹识别（每 30 秒一轮 Identify）。
#   libfprint 自带的温度模型按「识别操作运行了多久」估算温度，默认 180 秒即判定 HOT
#   （fp-device-private.h: DEFAULT_TEMP_HOT_SECONDS = 3 * 60），随后驱动返回
#   FP_DEVICE_ERROR_TOO_HOT → 框架报 “Device disabled to prevent overheating.” →
#   之后每次识别**瞬时失败**，而锁屏对话框把瞬时错误当失败并立即重试，
#   几秒内就把 MaxFailedTimes=5 烧光 → 亮屏即见「指纹失败，5 次机会全用完」。
#
#   上游 libfprint 里所有 match-on-chip 驱动（goodixmoc / fpcmoc / elanmoc /
#   synaptics / realtek / focaltech）都显式关闭该模型：dev_class->temp_hot_seconds = -1
#   （MOC 传感器自管温度）。本仓库的 fpc1553 移植漏了这行 → 落回 3 分钟默认值。
#   本驱动的空闲等待用的是 poll() + fingerdown_wait 的 IRQ 事件，
#   不是忙轮询/连续拍照，因此这个估算模型对它过度保守。
#
# 做法（等价于源码里的 `dev_class->temp_hot_seconds = -1;`）：
#   fp_device_constructed() 里选择温度模型参数的分支：
#       b8a4: b.le  b904          ; cls->temp_hot_seconds <= 0
#       b8a8: str   w0,[x19,#244] ;  > 0：用驱动声明的值
#       ...
#       b904: b.ne  b918          ; != 0（即 < 0）→ 走 b918
#       b908: ldr   d31,[x0,#3664]; == 0：用默认值对 (180, 540)   ← 3 分钟过热
#       b910: stur  d31,[x19,#244]
#       b918: mvni  v31.2s,#0x0   ; (-1, -1)                      ← 模型关闭
#       b91c: stur  d31,[x19,#244]
#   把 b904 的 `b.ne b918` 改成**无条件** `b b918`：默认分支也走 (-1,-1)，
#   即"本驱动声明不使用温度模型"，与上游其它 MOC 驱动的做法一致。
#
#   ⚠ 只改这一条 4 字节指令（编码 a1 00 00 54 → 05 00 00 14，实际只有 2 个字节不同），
#     因此**不触碰**同仓库自研的「按住即解锁」（wait_for_finger_lift）改动，
#     二进制其余部分与 payload 逐字节一致。
#
# 按字节模式定位（不硬编码偏移），幂等：已打过则原样通过。
#
# 用法：
#   tools/sheng-fp-thermal-off.sh <libfprint-2.so.2.0.0>
#   # 就地打补丁；成功后请更新 fingerprint_payload/libfprint-2.so.2.0.0
# =============================================================================
set -eu

SO=${1:?usage: $0 <libfprint-2.so.2.0.0>}

command -v python3 >/dev/null 2>&1 || { echo "需要 python3" >&2; exit 1; }

python3 - "$SO" <<'PY'
import sys

p = sys.argv[1]
data = bytearray(open(p, 'rb').read())

ORIG = bytes.fromhex("a1000054")   # b.ne 0xb918  (imm19 = +0x14)
NEW = bytes.fromhex("05000014")    # b    0xb918  (无条件)

# 上下文签名：b.ne 之后紧跟 adrp x0,<page> / ldr d31,[x0,#3664]
hits = []
start = 0
while True:
    i = data.find(ORIG, start)
    if i < 0:
        break
    nxt = bytes(data[i + 4:i + 12])
    if len(nxt) == 8 and nxt[0:4].hex().endswith("0090") and nxt[4:8].hex() == "1f2847fd":
        hits.append(i)
    start = i + 1

if not hits:
    print("已经是目标状态（未找到 b.ne 模式）——可能已打过补丁")
    sys.exit(0)
if len(hits) != 1:
    print("模式不唯一，找到 %d 处 —— 二进制版本变了吗？停止。" % len(hits), file=sys.stderr)
    sys.exit(1)

i = hits[0]
if bytes(data[i:i + 4]) == NEW:
    print("已打过补丁（offset %#x）" % i)
    sys.exit(0)

data[i:i + 4] = NEW
open(p, 'wb').write(bytes(data))
print("已打补丁：offset %#x  %s -> %s" % (i, ORIG.hex(), NEW.hex()))
print("提示：确认指纹仍能『按住即解锁』（本补丁不触及该逻辑），然后更新 fingerprint_payload/")
PY
