#!/bin/bash
# -*- coding: utf-8 -*-
# sheng-gesture-scroll-fix
# ---------------------------------------------------------------------------
# sheng / openKylin 3.0: 让文件管理器(peony)里**用手指点按能打开文件夹**，
# 同时**保留一指触摸滚动**。
#
# 根因（Xiaomi Pad 6S Pro / sheng 实机验证）：
#   UKUI 的手势插件 libqt5-gesture-extensions（由 ukui Qt 样式对每个
#   QAbstractScrollArea 自动注册）会调用
#       QScroller::grabGesture(viewport, QScroller::TouchGesture)
#   而 `grabGesture(TouchGesture)` 会顺带给 viewport 设
#   `Qt::WA_AcceptTouchEvents` —— 部件一旦接收触摸事件，**Qt 就不再把它合成鼠标
#   事件**。peony 是靠**鼠标双击**打开的，于是"没有鼠标事件"→ 可滚动目录里用
#   手指怎么点都打不开（放得下、不滚动的目录 QScroller 不介入，仍走 Qt 合成 →
#   正常；鼠标不受影响）。该手势扩展设的 QScrollerProperties **无关**（改
#   MaximumClickThroughVelocity 实测无效）。
#
# 修法：把该手势类型从 TouchGesture(0) 改成 LeftMouseButtonGesture(1)。
#   这样不再设 WA_AcceptTouchEvents → 触摸重新被合成为鼠标（双击成立、能打开），
#   而 QScroller 改为抓"鼠标拖拽 flick" → 一指拖动仍能滚动。
#
# 以极小代码补丁就地改 arm64 .so（无需源码重编）：
#   SlideGesture::registerWidget 里那段唯一的 8 字节序列
#       mov w1, #0 ; mov x20, x0        (= 01 00 80 52 f4 03 00 aa, 小端 aarch64)
#   改成
#       mov w1, #1 ; mov x20, x0        (= 21 00 80 52 f4 03 00 aa)
#   按**字节模式**定位（非硬编码偏移），幂等。等价源码改动：
#   qt5-gesture-extensions/gesture-extensions/slide-gesture.cpp 的 registerWidget()
#   把 QScroller::grabGesture(viewport, QScroller::TouchGesture); 改成
#   QScroller::grabGesture(viewport, QScroller::LeftMouseButtonGesture);
#
# 用法:
#   sheng-gesture-scroll-fix.sh [ROOTFS_DIR]     # 默认 "/"（实机）
#   （ROOTFS_DIR = 构建时解出的 rootfs 路径）
# ---------------------------------------------------------------------------
set -e
ROOT="${1:-/}"
ROOT="${ROOT%/}"
LIB="$ROOT/usr/lib/aarch64-linux-gnu/libqt5-gesture-extensions.so.1.0.0"

if [ ! -f "$LIB" ]; then
    echo "sheng-gesture-scroll-fix: 未找到 $LIB，跳过（镜像里没有该库？）"
    exit 0
fi

python3 - "$LIB" <<'PY'
import sys, os, shutil
lib = sys.argv[1]
OLD = bytes.fromhex("01008052f40300aa")   # mov w1,#0 ; mov x20,x0  -> TouchGesture
NEW = bytes.fromhex("21008052f40300aa")   # mov w1,#1 ; mov x20,x0  -> LeftMouseButtonGesture
d = open(lib, "rb").read()
if d.count(NEW) == 1 and d.count(OLD) == 0:
    print("sheng-gesture-scroll-fix: 已打过补丁，跳过")
    sys.exit(0)
n = d.count(OLD)
if n != 1:
    print("sheng-gesture-scroll-fix: 警告：未找到唯一匹配（找到 %d 处），库版本可能不同，跳过" % n)
    sys.exit(0)
bak = lib + ".gesturebak.orig"
if not os.path.exists(bak):
    shutil.copy2(lib, bak)
off = d.find(OLD)
open(lib, "wb").write(d[:off] + NEW + d[off + len(OLD):])
print("sheng-gesture-scroll-fix: 已补丁 @0x%x （grabGesture: TouchGesture -> LeftMouseButtonGesture）" % off)
PY
