#!/bin/bash
# -*- coding: utf-8 -*-
# sheng-power-button-blank-fix
# ---------------------------------------------------------------------------
# sheng / openKylin 3.0: make "设置 → 电源 → 按下电源键时执行" offer a working
# "关闭显示器" (Blank) action that turns the panel off, and pressing it again
# turns it back on.
#
# Background (verified on the Xiaomi Pad 6S Pro / sheng):
#   * The dropdown is built by the control-center power plugin
#     usr/lib/aarch64-linux-gnu/ukui-control-center/libpower.so (owned by the
#     ukui-power-manager package, which dpkg-divert-installs it over
#     ukui-control-center's own copy).  Power::setupComponent() hard-codes the
#     option list to Interactive / Shutdown / Suspend / Hibernate — no "blank".
#     PART 1 below adds it by repurposing the dead hibernate branch (sheng has
#     no hibernation: /sys/power/state == "freeze mem").  Selecting it writes
#     gsettings org.ukui.power-manager button-power == "blank".
#   * The *handler* of the hardware power key is the media-keys plugin of
#     ukui-settings-daemon: usr/lib/aarch64-linux-gnu/ukui-settings-daemon/
#     libmedia-keys.so.  Power::doPowerKeyAction() reads button-power's enum
#     index and calls doSessionAction(PowerType).  PowerType (media-type.h) is
#     { POWER_SUSPEND=1, POWER_SHUTDOWN=2, POWER_HIBERNATE=3, POWER_INTER_ACTIVE=4 }
#     — index 0 ("blank") has no case, so it falls through to
#     executeCommand("ukui-session-tools", {}) which just shows the session
#     menu.  PART 2 repoints that program string to our wrapper "sheng-pwrkey",
#     which runs /usr/local/bin/sheng-screen-toggle when button-power=="blank"
#     and otherwise execs the real ukui-session-tools (passthrough for
#     suspend/shutdown/hibernate/interactive).  The string is referenced ONLY by
#     doSessionAction, so the control center / panel are unaffected.
#
#   * Bonus (PART 3): the TIMED blank ("此时间段后关闭显示器") never locked either,
#     because ukui-powermanagement's IdlenessWatcher runs the lock via
#     QProcess::start("ukui-screensaver-command -b idle") — and Qt's
#     QProcess::start(program) does NOT split on spaces, so it execs a
#     non-existent file named "ukui-screensaver-command -b idle" -> fails -> no
#     lock.  Repoints that program string to the no-space wrapper
#     /usr/local/bin/sheng-idle-lock (runs `ukui-screensaver-command --lock` when
#     close-activation-enabled is on).
#
# Helpers installed by the overlay: /usr/bin/sheng-pwrkey,
# /usr/local/bin/sheng-screen-toggle, /usr/local/bin/sheng-idle-lock.
# Equivalent SOURCE changes: docs/patches/ukui-power-manager-power-button-blank.patch,
# docs/patches/ukui-settings-daemon-power-button-blank.patch and
# docs/patches/ukui-power-manager-idle-lock-screensaver.patch.
#
# Usage: sheng-power-button-blank-fix.sh [ROOTFS_DIR]     # default: live "/"
# Idempotent.  Each modified file is backed up once to <file>.sheng-pwrkey.orig.
# ---------------------------------------------------------------------------
set -e
ROOT="${1:-/}"
ROOT="${ROOT%/}"

python3 - "$ROOT" <<'PY'
import os, subprocess, sys, shutil

root = (sys.argv[1] or "/").rstrip("/") or "/"

def text_sec(path):
    out = subprocess.run(["readelf", "-SW", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        t = line.split()
        if ".text" in t:
            i = t.index(".text")
            if i + 3 < len(t) and t[i + 1] == "PROGBITS":
                return int(t[i + 2], 16), int(t[i + 3], 16)   # sh_addr, sh_offset
    return None

def sym_vaddr(path, needle):
    out = subprocess.run(["nm", "-DC", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        t = line.split()
        if len(t) >= 3 and " T " in line and needle in line:
            return int(t[0], 16)
    return None

# ---- PART 1: libpower.so — dead hibernate insert -> Blank/blank -------------
lp = os.path.join(root, "usr/lib/aarch64-linux-gnu/ukui-control-center/libpower.so")
if os.path.isfile(lp):
    sym = sym_vaddr(lp, "Power::setupComponent()")
    sec = text_sec(lp)
    if sym is not None and sec is not None:
        addr, off0 = sec
        edits = [
            (0x3e4, 0x36000200, 0xd503201f),   # force the (dead) hibernate branch to run
            (0x3f4, 0x91214021, 0x9120c021),   # data "hibernate" -> "blank"
            (0x314, 0x91206001, 0x911fe001),   # label tr("Hibernate") -> tr("Blank")
        ]
        b = bytearray(open(lp, "rb").read())
        done = 0
        bak = lp + ".sheng-pwrkey.orig"
        for rel, old, new in edits:
            fo = sym + rel - addr + off0
            cur = int.from_bytes(b[fo:fo + 4], "little")
            if cur == new:
                continue
            if cur != old:
                sys.stderr.write("libpower.so: unexpected %08x at +0x%x (skip)\n" % (cur, rel))
                continue
            if not os.path.exists(bak):
                shutil.copy2(lp, bak)
            b[fo:fo + 4] = new.to_bytes(4, "little")
            done += 1
        if done:
            open(lp, "wb").write(b)
        print("libpower.so: %d edit(s) applied" % done)
    else:
        sys.stderr.write("libpower.so: Power::setupComponent()/.text not found -- dropdown NOT patched\n")
else:
    sys.stderr.write("libpower.so not found at %s\n" % lp)

# ---- PART 2: libmedia-keys.so — repoint "ukui-session-tools" program -------
lm = os.path.join(root, "usr/lib/aarch64-linux-gnu/ukui-settings-daemon/libmedia-keys.so")
if os.path.isfile(lm):
    data = bytearray(open(lm, "rb").read())
    OLD = b"sheng-pwrkey\x00" + b"\x00" * (19 - len(b"sheng-pwrkey\x00"))
    NEW = OLD
    OLDSTR = b"ukui-session-tools\x00"
    if bytes(data).find(NEW) != -1:
        print("libmedia-keys.so: already patched")
    else:
        idx = bytes(data).find(OLDSTR)
        if idx < 0:
            sys.stderr.write("libmedia-keys.so: 'ukui-session-tools' not found -- handler NOT patched\n")
        elif bytes(data).find(OLDSTR, idx + 1) != -1:
            sys.stderr.write("libmedia-keys.so: multiple 'ukui-session-tools' strings -- ambiguous, NOT patched\n")
        else:
            bak = lm + ".sheng-pwrkey.orig"
            if not os.path.exists(bak):
                shutil.copy2(lm, bak)
            data[idx:idx + 19] = b"sheng-pwrkey\x00" + b"\x00" * 6
            open(lm, "wb").write(bytes(data))
            print("libmedia-keys.so: program string repointed to sheng-pwrkey @0x%x" % idx)
else:
    sys.stderr.write("libmedia-keys.so not found at %s\n" % lm)

# ---- PART 3: ukui-powermanagement — fix "lock on (timed) blank" ------------
# Its IdlenessWatcher, on the idle display-off, does
#     QProcess process; process.start("ukui-screensaver-command -b idle");
# but Qt's QProcess::start(program) does NOT split on spaces -> it tries to exec
# a file literally named "ukui-screensaver-command -b idle" -> FailedToStart ->
# the TIMED blank never locks (while the power-key blank does).  Repoint that
# program string to the no-space wrapper /usr/local/bin/sheng-idle-lock.
up = os.path.join(root, "usr/bin/ukui-powermanagement")
if os.path.isfile(up):
    data = bytearray(open(up, "rb").read())
    OLD = b"ukui-screensaver-command -b idle"
    NEW = b"/usr/local/bin/sheng-idle-lock"
    slot = len(OLD) + 1
    pad = NEW + b"\x00" * (slot - len(NEW))
    if bytes(data).find(NEW) != -1:
        print("ukui-powermanagement: already patched")
    else:
        idx = bytes(data).find(OLD)
        if idx < 0:
            sys.stderr.write("ukui-powermanagement: idle-lock string not found -- "
                             "timed blank will NOT lock\n")
        else:
            bak = up + ".sheng-idle.orig"
            if not os.path.exists(bak):
                shutil.copy2(up, bak)
            data[idx:idx + slot] = pad
            open(up, "wb").write(bytes(data))
            print("ukui-powermanagement: idle-lock program repointed -> sheng-idle-lock @0x%x" % idx)
else:
    sys.stderr.write("ukui-powermanagement not found at %s\n" % up)
PY
