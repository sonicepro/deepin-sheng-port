#!/bin/bash
# -*- coding: utf-8 -*-
# sheng-usd-brightness-fix
# ---------------------------------------------------------------------------
# sheng / openKylin 3.0: stop ukui-settings-daemon from resetting the screen
# brightness to MAX on every output reconfiguration (screen rotation) and at
# session start.
#
# Root cause (verified on the Xiaomi Pad 6S Pro / sheng):
#   `UsdBaseClass::upmSupportAdjustBrightness()` only checks that a
#   /sys/class/backlight/<node>/brightness file exists.  On sheng the panel
#   exposes ktz8866-backlight, but openKylin's upm cannot drive it
#   (`org.ukui.powermanagement` -> CanSetBrightness == false).  So the function
#   returns true and the compositor gamma-manager (the brightness authority used
#   by the UKUI brightness bar) treats the first -- and only -- output as a
#   "notebook internal panel" and pegs its brightness to 100 on every screen
#   reconfiguration (`GmHelper::updateWlcomOutputInfo()` etc.).  The user's
#   setting is therefore lost on rotate / reboot.
#
# Fix: make that function return false, so the compositor gamma-manager owns
# brightness and preserves it across reconfiguration / session start via its own
# store (/etc/ukui/usd/globalconf.ini, section [color]).
#
# This script patches the *compiled* copies of that function in the daemon
# binary and in every plugin .so that exports it (they each statically link the
# shared helper, and the symbol is interposed).  It is architecture-agnostic for
# the build host: nm/readelf/python only read the (arm64) ELF bytes, so it runs
# fine on an x86 build machine.  The equivalent SOURCE change is stored at
# docs/patches/ukui-settings-daemon-upmSupportAdjustBrightness.patch for a proper
# rebuild.
#
# Usage:
#   sheng-usd-brightness-fix.sh [ROOTFS_DIR]      # default: live "/"
#   (ROOTFS_DIR = extracted-rootfs path during image builds)
#
# Idempotent.  Each modified file is backed up once to <file>.usdbak.orig.
# ---------------------------------------------------------------------------
set -e
ROOT="${1:-/}"
ROOT="${ROOT%/}"

python3 - "$ROOT" <<'PY'
import os, subprocess, sys, shutil
root = sys.argv[1] or "/"
sub  = "usr/lib/aarch64-linux-gnu/ukui-settings-daemon"
plain = "usr/lib/ukui-settings-daemon"   # fallback layout
libdirs = [os.path.join(root, sub), os.path.join(root, plain)]

targets = [os.path.join(root, "usr/bin/ukui-settings-daemon")]
for d in libdirs:
    if os.path.isdir(d):
        targets += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".so")]

PAY = bytes([0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])  # aarch64: mov w0,#0 ; ret
SYM = "upmSupportAdjustBrightness"

def sym_vaddr(path):
    try:
        out = subprocess.run(["nm", "-DC", path], capture_output=True, text=True).stdout
    except Exception:
        return None
    for line in out.splitlines():
        t = line.split()
        if len(t) >= 3 and " T " in line and SYM in line:
            return int(t[0], 16)
    return None

def text_sec(path):
    try:
        out = subprocess.run(["readelf", "-SW", path], capture_output=True, text=True).stdout
    except Exception:
        return None
    for line in out.splitlines():
        t = line.split()
        if ".text" in t:
            i = t.index(".text")
            if i + 3 < len(t) and t[i + 1] == "PROGBITS":
                return int(t[i + 2], 16), int(t[i + 3], 16)  # sh_addr, sh_offset
    return None

patched = 0
daemon = os.path.join(root, "usr/bin/ukui-settings-daemon")
daemon_ok = False
skipped = []
for p in targets:
    if not os.path.isfile(p):
        continue
    va = sym_vaddr(p)
    if va is None:
        skipped.append(os.path.basename(p)); continue
    sec = text_sec(p)
    if sec is None:
        skipped.append(os.path.basename(p)); continue
    addr, off0 = sec
    foff = va - addr + off0
    b = bytearray(open(p, "rb").read())
    cur = bytes(b[foff:foff + 8])
    if cur == PAY:
        print("ok (already): %s" % os.path.basename(p))
        if p == daemon: daemon_ok = True
        continue
    # sanity: must look like an AArch64 function prologue
    if not (cur[3] in (0xd1, 0xa9, 0xf8) or cur[:4] == b"\x3f\x23\x03\xd5"):
        print("SKIP (unexpected prologue) %s @0x%x : %s" % (os.path.basename(p), foff, cur.hex()))
        skipped.append(os.path.basename(p)); continue
    bak = p + ".usdbak.orig"
    if not os.path.exists(bak):
        shutil.copy2(p, bak)
    b[foff:foff + 8] = PAY
    open(p, "wb").write(b)
    print("patched %s @0x%x" % (os.path.basename(p), foff))
    if p == daemon: daemon_ok = True
    patched += 1
print("sheng-usd-brightness-fix: patched %d file(s) (root=%s)" % (patched, root))
if skipped:
    print("  (no symbol / skipped: %s)" % ", ".join(sorted(set(skipped))))
if not daemon_ok:
    sys.stderr.write(
        "ERROR: UsdBaseClass::upmSupportAdjustBrightness() not found in %s\n"
        "       (ukui-settings-daemon changed?) -- brightness reset NOT fixed.\n" % daemon)
    sys.exit(2)
PY

# --- compositor brightness neutralisation -----------------------------------
# ukui-settings-daemon maps the slider 0..100 onto the kylin-wlcom *software*
# brightness (GmHelper::normalizeBrightness -> compositor SetBrightness), a
# per-pixel multiply in the compositor that crushes dark tones (bad dark-scene
# rendering).  We want the real panel backlight to carry the brightness, so pin
# the compositor to N (== no dim) by rewriting BOTH mapper bodies to
# `mov w0,#N ; ret`.  The user value is still persisted by the daemon in
# /etc/ukui/usd/globalconf.ini [color] <output> independently of the compositor,
# and the sheng-panel-brightness daemon reads it to drive
# /sys/class/backlight/ktz8866-backlight.
SHENG_COMPOSITOR_BRIGHTNESS="${SHENG_COMPOSITOR_BRIGHTNESS:-100}"
python3 - "$ROOT" "$SHENG_COMPOSITOR_BRIGHTNESS" <<'PY'
import os, subprocess, sys, shutil
root = (sys.argv[1] or "/").rstrip("/") or "/"
lvl  = int(sys.argv[2])
libdirs = [os.path.join(root, "usr/lib/aarch64-linux-gnu/ukui-settings-daemon"),
           os.path.join(root, "usr/lib/ukui-settings-daemon")]

def enc_mov_w0(n): return (0x52800000 | ((n & 0xffff) << 5)).to_bytes(4, "little")  # mov w0,#n
PAY  = enc_mov_w0(lvl) + (0xd65f03c0).to_bytes(4, "little")  # mov w0,#N ; ret
SYMS = ("GmHelper::normalizeBrightness", "GmHelper::denormalizeBrightness")

# first-instruction byte patterns we accept before overwriting: the original
# function prologue (sub sp / stp / pac), or a `mov w0,#imm` (top byte 0x52,
# i.e. the old "floor" payload this tool used to write) for idempotency.
def plausible(first4):
    return first4[3] in (0x52, 0xd1, 0xa9, 0xf8)

def sym_vaddr(path, name):
    try: out = subprocess.run(["nm", "-DC", path], capture_output=True, text=True).stdout
    except Exception: return None
    for line in out.splitlines():
        t = line.split()
        if len(t) >= 3 and " T " in line and name in line:
            return int(t[0], 16)
    return None

def text_sec(path):
    try: out = subprocess.run(["readelf", "-SW", path], capture_output=True, text=True).stdout
    except Exception: return None
    for line in out.splitlines():
        t = line.split()
        if ".text" in t:
            i = t.index(".text")
            if i + 3 < len(t) and t[i + 1] == "PROGBITS":
                return int(t[i + 2], 16), int(t[i + 3], 16)
    return None

cands = [os.path.join(root, "usr/bin/ukui-settings-daemon")]
for d in libdirs:
    if os.path.isdir(d):
        cands += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".so")]
seen = 0
for p in cands:
    if not os.path.isfile(p): continue
    sec = text_sec(p)
    if sec is None: continue
    addr, off0 = sec
    for name in SYMS:
        va = sym_vaddr(p, name)
        if va is None: continue
        foff = va - addr + off0
        b = bytearray(open(p, "rb").read())
        cur = bytes(b[foff:foff + 8])
        if cur == PAY:
            print("ok (already): %s %s" % (os.path.basename(p), name)); seen += 1; continue
        if not plausible(cur):
            print("SKIP (unexpected prologue) %s %s @0x%x : %s" % (os.path.basename(p), name, foff, cur.hex())); continue
        bak = p + ".usdbak.orig"
        if not os.path.exists(bak): shutil.copy2(p, bak)
        b[foff:foff + 8] = PAY
        open(p, "wb").write(b)
        print("patched %s %s @0x%x (compositor->%d)" % (os.path.basename(p), name, foff, lvl)); seen += 1
print("sheng-usd-brightness-fix: compositor brightness pinned to %d, mappers patched=%d" % (lvl, seen))
if seen == 0:
    sys.stderr.write("ERROR: GmHelper::normalize/denormalizeBrightness not found -- "
                     "compositor brightness NOT neutralised.\n")
    sys.exit(3)
PY
