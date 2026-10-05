#!/bin/bash
# Spark Store (Electron/Chromium) screen-corruption ("花屏") workaround.
#
# On the sheng/SM8550 mainline graphics stack (msm DRM + Mesa freedreno +
# Adreno A740, Wayland kylin-wlcom / Xwayland), Chromium's GPU process is
# unstable and crashes (SIGSEGV) -> Spark Store renders a garbled screen.
# The upstream spark-store launcher used to add '--disable-gpu' for
# arm64 + Wayland and explicitly removed it, so re-add it.
#
# Idempotent and safe to run repeatedly (boot + after any package operation).
# No-op when spark-store is not installed or already patched.
set -u

W=/opt/durapps/spark-store/bin/spark-store
[ -f "$W" ] || exit 0
# NB: the pristine launcher already contains '--disable-gpu' (loongArch branch),
# so match the exact base ARGS line, not the whole file.
grep -q '^ARGS="--no-sandbox --disable-gpu"' "$W" && exit 0
sed -i 's/^\(ARGS="--no-sandbox\)"/\1 --disable-gpu"/' "$W"
exit 0
