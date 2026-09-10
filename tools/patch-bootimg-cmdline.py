#!/usr/bin/env python3
"""Patch the cmdline of an Android boot.img (header v0) in place.

Header-v0 layout (offsets):
  0 magic[8] | 8 kernel_size | 12 kernel_addr | 16 ramdisk_size | 20 ramdisk_addr
  24 second_size | 28 second_addr | 32 tags_addr | 36 page_size | 40 header_version
  44 os_version | 48 name[16] | 64 cmdline[512] | 576 id[32] | 608 extra_cmdline[1024]

The id (SHA1) covers kernel/ramdisk/second only, so rewriting cmdline is safe.
Usage: patch-bootimg-cmdline.py <in.img> <out.img> "<cmdline>"
"""
import sys

BOOT_ARGS_SIZE = 512
CMDLINE_OFF = 64
HEADER_VERSION_OFF = 40


def patch(src, dst, cmdline):
    data = bytearray(open(src, "rb").read())
    if bytes(data[:8]) != b"ANDROID!":
        raise SystemExit(f"{src}: not an Android boot image")
    hv = int.from_bytes(data[HEADER_VERSION_OFF:HEADER_VERSION_OFF + 4], "little")
    if hv != 0:
        raise SystemExit(f"{src}: header v{hv}; this patcher only handles v0")
    cb = cmdline.encode()
    if len(cb) + 1 > BOOT_ARGS_SIZE:
        raise SystemExit(f"cmdline is {len(cb)}B, over the {BOOT_ARGS_SIZE}B limit")
    data[CMDLINE_OFF:CMDLINE_OFF + BOOT_ARGS_SIZE] = b"\x00" * BOOT_ARGS_SIZE
    data[CMDLINE_OFF:CMDLINE_OFF + len(cb)] = cb
    open(dst, "wb").write(data)
    print(f"{src} -> {dst}   cmdline({len(cb)}B): {cmdline}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    patch(sys.argv[1], sys.argv[2], sys.argv[3])
