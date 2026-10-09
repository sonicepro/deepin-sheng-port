#!/usr/bin/env python3
# sheng-osk-tap — open the on-screen keyboard on a DOUBLE-tap.
#
# openKylin's on-screen keyboard (kylin-virtual-keyboard, driven by fcitx5)
# otherwise pops whenever a text field gains focus — including when a UI
# auto-focuses a field (e.g. WeChat switching chats). The companion LD_PRELOAD
# gate (sheng-osk-gate.so) swallows that automatic pop.
#
# This daemon reads the touchscreen (Linux MT protocol B — read-only, never
# grabs) and opens the keyboard only on a deliberate DOUBLE-tap: two clean taps
# (short, almost no movement) close together in time and space. A single tap —
# tapping a friend in a list, a button, scrolling, dragging — does nothing.
#
# env: OSK_TAP_DRYRUN=1  -> don't call D-Bus, just log (for testing)

import glob
import os
import struct
import sys
import time

# ---- tunables (touch units: X 0..30480, Y 0..20320; ~10x screen px) ----
DEVICE_NAME      = "NVTCapacitiveTouchScreen"
MAX_TAP_DURATION = 0.35    # a single tap = finger down..up within this (seconds)
MAX_TAP_MOVE     = 260     # ...and moving no further than this (touch units)
DBL_TAP_GAP      = 0.45    # max time between the two taps of a double-tap
DBL_TAP_DIST     = 350     # max distance between the two taps (touch units)

DBUS_NAME   = "org.fcitx.Fcitx5"
DBUS_PATH   = "/virtualkeyboard"
DBUS_IFACE  = "org.fcitx.Fcitx.VirtualKeyboard1"
DBUS_METHOD = "ShowVirtualKeyboard"

VIS_NAME  = "org.fcitx.Fcitx5.VirtualKeyboard"
VIS_PATH  = "/org/fcitx/virtualkeyboard/impanel"
VIS_IFACE = "org.fcitx.Fcitx5.VirtualKeyboard1"

TEXTACTIVE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "sheng-osk-textactive")

# ---- evdev constants ----
EV_SYN, EV_ABS = 0x00, 0x03
SYN_REPORT = 0x00
ABS_MT_SLOT        = 0x2f
ABS_MT_POSITION_X  = 0x35
ABS_MT_POSITION_Y  = 0x36
ABS_MT_TRACKING_ID = 0x39
EVENT = struct.Struct("llHHi")   # struct input_event (64-bit timeval)


def log(msg):
    sys.stderr.write("sheng-osk-tap: %s\n" % msg)
    sys.stderr.flush()


def find_device():
    for ev in sorted(glob.glob("/dev/input/event*")):
        namef = "/sys/class/input/%s/device/name" % os.path.basename(ev)
        try:
            with open(namef) as f:
                if f.read().strip() == DEVICE_NAME:
                    return ev
        except OSError:
            continue
    return None


def _bus():
    from gi.repository import Gio
    return Gio.bus_get_sync(Gio.BusType.SESSION, None)


def read_textactive():
    try:
        with open(TEXTACTIVE) as f:
            return f.read().strip()
    except Exception:
        return "0"


def is_visible():
    try:
        r = _bus().call_sync(VIS_NAME, VIS_PATH, VIS_IFACE,
                             "IsVirtualKeyboardVisible",
                             None, None, 0, -1, None)
        return r.unpack()[0]
    except Exception:
        return None


def show_keyboard():
    _bus().call_sync(DBUS_NAME, DBUS_PATH, DBUS_IFACE, DBUS_METHOD,
                     None, None, 0, -1, None)


def run(dev, dry):
    # dev == "-" reads from stdin (for offline testing with a synthetic stream)
    fd = 0 if dev == "-" else os.open(dev, os.O_RDONLY)
    slots = {}
    cur = 0
    buf = b""
    prev_n = 0
    gest = None
    last_tap = None   # (t, x, y) of the previous clean tap
    try:
        while True:
            data = os.read(fd, EVENT.size * 64)
            if not data:
                return  # EOF (test stream only; a real evdev never EOFs)
            buf += data
            usable = len(buf) - (len(buf) % EVENT.size)
            for off in range(0, usable, EVENT.size):
                _s, _u, etype, code, value = EVENT.unpack_from(buf, off)
                if etype == EV_ABS:
                    if code == ABS_MT_SLOT:
                        cur = value
                    elif code == ABS_MT_TRACKING_ID:
                        slots.setdefault(cur, [None, 0, 0])[0] = value
                    elif code == ABS_MT_POSITION_X:
                        slots.setdefault(cur, [None, 0, 0])[1] = value
                    elif code == ABS_MT_POSITION_Y:
                        slots.setdefault(cur, [None, 0, 0])[2] = value
                elif etype == EV_SYN and code == SYN_REPORT:
                    pts = [(s[1], s[2]) for s in slots.values()
                           if s[0] is not None and s[0] >= 0]
                    n = len(pts)
                    now = time.monotonic()
                    if n == 1 and prev_n == 0:
                        gest = {"t0": now, "x0": pts[0][0], "y0": pts[0][1],
                                "xl": pts[0][0], "yl": pts[0][1]}
                    elif n == 1 and gest is not None:
                        gest["xl"], gest["yl"] = pts[0]
                    elif n == 0 and gest is not None:
                        dur = now - gest["t0"]
                        dx = gest["xl"] - gest["x0"]
                        dy = gest["yl"] - gest["y0"]
                        move = (dx * dx + dy * dy) ** 0.5
                        if dur <= MAX_TAP_DURATION and move <= MAX_TAP_MOVE:
                            x, y = gest["xl"], gest["yl"]
                            if (last_tap is not None
                                    and (now - last_tap[0]) <= DBL_TAP_GAP
                                    and ((x - last_tap[1]) ** 2 +
                                         (y - last_tap[2]) ** 2) ** 0.5
                                    <= DBL_TAP_DIST):
                                last_tap = None
                                active = read_textactive()
                                vis = is_visible()
                                if active != "1":
                                    log("double-tap(%d,%d) -> skip (no text field focused)"
                                        % (x, y))
                                elif vis is False:
                                    log("double-tap(%d,%d) -> show (text field focused)"
                                        % (x, y))
                                    if not dry:
                                        try:
                                            show_keyboard()
                                        except Exception as e:
                                            log("   D-Bus call failed: %r" % (e,))
                                else:
                                    log("double-tap(%d,%d) -> skip (already visible)"
                                        % (x, y))
                            else:
                                last_tap = (now, x, y)
                                log("tap(%d,%d) (waiting for 2nd)" % (x, y))
                        gest = None
                    elif n >= 2:
                        gest = None   # multi-finger: not a tap
                    prev_n = n
            buf = buf[usable:]
    finally:
        if fd != 0:
            os.close(fd)


def main():
    dry = os.environ.get("OSK_TAP_DRYRUN") == "1"
    fixed = sys.argv[1] if len(sys.argv) > 1 else None
    if fixed == "-":
        run("-", dry)
        return
    while True:
        dev = fixed or find_device()
        if not dev:
            log("device %r not found; retrying in 5s" % DEVICE_NAME)
            time.sleep(5)
            continue
        log("watching %s (dry=%s)" % (dev, dry))
        try:
            run(dev, dry)
        except OSError as e:
            log("read error on %s: %r; reopening in 3s" % (dev, e))
            time.sleep(3)


if __name__ == "__main__":
    main()
