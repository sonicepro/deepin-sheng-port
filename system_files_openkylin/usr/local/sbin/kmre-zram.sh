#!/bin/sh
# Enable a zstd zram swap device. Without swap, opening a second Android app makes
# the kernel reclaim by dropping page cache and/or killing processes, which is what
# makes the launch of the 2nd app janky on this 12 GiB device. zram gives ~3x
# compressed swap (zstd) so cold pages move out cheaply and apps stay resident.
# (kernel: CONFIG_ZRAM=m + CONFIG_ZSMALLOC=m, backend zstd.)
set -e
# Idempotent: if any zram swap is already active, just (re)assert swappiness and go.
if grep -q zram /proc/swaps 2>/dev/null; then
    echo 100 > /proc/sys/vm/swappiness 2>/dev/null || true
    exit 0
fi
modprobe zram 2>/dev/null || true
Z="$(zramctl --find --size 4G --algorithm zstd 2>/dev/null || echo /dev/zram0)"
mkswap "$Z" >/dev/null
swapon "$Z"
# Android-style aggressiveness: move cold pages to zram early.
echo 100 > /proc/sys/vm/swappiness 2>/dev/null || true
