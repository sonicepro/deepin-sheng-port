#!/usr/bin/env python3
# sheng-gesture-keyboard — bring up the on-screen keyboard with a 3-finger swipe up.
#
# Reads the touchscreen (Linux multi-touch protocol B) directly from evdev and
# calls org.onboard.Onboard.Keyboard.Show() on the session bus.
#
# It only READS the device (never grabs it), so X input and DDE's own gesture
# handling keep working normally.
#
# Coordinate note: this panel reports Y growing downward (0 = top, max = bottom),
# so an upward swipe makes Y decrease and dy (= last - start) is negative.

import os
import glob
import struct
import sys
import time

# ---- tunables (touch units: X 0..30480, Y 0..20320; ~10x screen px) ----
DEVICE_NAME  = "NVTCapacitiveTouchScreen"
FINGERS      = 3
MIN_UP       = 3000      # minimum upward travel to count as a swipe
MAX_CROSS    = 0.70      # |dx| must be < MAX_CROSS * |dy|
MAX_DURATION = 0.90      # seconds from touch-down to lift
DEBOUNCE     = 1.00      # seconds between two triggers
DBUS_NAME    = "org.onboard.Onboard"
DBUS_PATH    = "/org/onboard/Onboard/Keyboard"
DBUS_IFACE   = "org.onboard.Onboard.Keyboard"
DBUS_METHOD  = "Show"    # "Show" (summon) or "ToggleVisible" (show/hide)

# ---- evdev constants ----
EV_SYN, EV_ABS = 0x00, 0x03
SYN_REPORT = 0x00
ABS_MT_SLOT        = 0x2f
ABS_MT_POSITION_X  = 0x35
ABS_MT_POSITION_Y  = 0x36
ABS_MT_TRACKING_ID = 0x39

# struct input_event { struct timeval time; __u16 type; __u16 code; __s32 value; }
# timeval is 2 x long, so this is 24 bytes on 64-bit.
EVENT = struct.Struct("llHHi")


def log(msg):
    sys.stderr.write("sheng-gesture-keyboard: %s\n" % msg)
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


def call_onboard():
    from gi.repository import Gio
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    bus.call_sync(DBUS_NAME, DBUS_PATH, DBUS_IFACE, DBUS_METHOD,
                  None, None, Gio.DBusCallFlags.NONE, -1, None)


def run(dev):
    # dev == "-" reads from stdin (for offline testing with a synthetic stream)
    fd = 0 if dev == "-" else os.open(dev, os.O_RDONLY)
    slots = {}          # slot -> [tracking_id, x, y]
    cur = 0
    buf = b""
    in_g = False
    gx0 = gy0 = gxl = gyl = 0.0
    gt0 = 0.0
    last = 0.0
    try:
        while True:
            data = os.read(fd, EVENT.size * 64)
            if not data:
                return  # EOF (only happens on a test stream; evdev never EOFs)
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
                    if not in_g:
                        if n == FINGERS:
                            in_g = True
                            gx0 = sum(p[0] for p in pts) / n
                            gy0 = sum(p[1] for p in pts) / n
                            gxl, gyl = gx0, gy0
                            gt0 = now
                    elif n == FINGERS:
                        gxl = sum(p[0] for p in pts) / n
                        gyl = sum(p[1] for p in pts) / n
                    else:
                        in_g = False
                        dy = gyl - gy0
                        dx = gxl - gx0
                        dur = now - gt0
                        if (dy <= -MIN_UP and abs(dx) <= MAX_CROSS * abs(dy)
                                and dur <= MAX_DURATION
                                and (now - last) >= DEBOUNCE):
                            log("3-finger swipe up (dy=%.0f dx=%.0f dur=%.2fs) -> %s()"
                                % (dy, dx, dur, DBUS_METHOD))
                            last = now
                            try:
                                call_onboard()
                            except Exception as e:  # onboard not up yet, etc.
                                log("D-Bus call failed: %r" % (e,))
            buf = buf[usable:]
    finally:
        if fd != 0:
            os.close(fd)


def main():
    fixed = sys.argv[1] if len(sys.argv) > 1 else None
    if fixed == "-":
        run("-")
        return
    while True:
        dev = fixed or find_device()
        if not dev:
            log("device %r not found; retrying in 5s" % DEVICE_NAME)
            time.sleep(5)
            continue
        log("watching %s" % dev)
        try:
            run(dev)
        except OSError as e:
            log("read error on %s: %r; reopening in 3s" % (dev, e))
            time.sleep(3)


if __name__ == "__main__":
    main()
