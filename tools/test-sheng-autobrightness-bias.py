#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline regression test for the sheng-autobrightness user-bias logic.

Loads the daemon as a module, replaces the sensor / D-Bus / clock with fakes and
drives `main()` for a scripted number of virtual seconds. It needs no tablet, no
session bus and no light sensor, so it runs anywhere:

    python3 tools/test-sheng-autobrightness-bias.py

Covered:
  [1] a manual raise is learned as bias = manual - curve(lux)
  [2] that bias rides along when the ambient light changes
  [3] a persisted bias survives a restart without snapping the screen back
  [4] a lagging bus readback after our own write is not a phantom bias
  [5] a single-tick blip (bus/bridge race) is not learned
  [6] `--reset-offset` is picked up by a running daemon
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

_DAEMON_REL = os.path.join("system_files_openkylin", "usr", "local", "bin",
                           "sheng-autobrightness")
DAEMON = None
for _base in (HERE, os.path.dirname(HERE), os.path.join(HERE, "..", "..")):
    _p = os.path.abspath(os.path.join(_base, _DAEMON_REL))
    if os.path.isfile(_p):
        DAEMON = _p
        break
if DAEMON is None:
    sys.stderr.write("cannot locate %s near %s\n" % (_DAEMON_REL, HERE))
    sys.exit(2)

KNOBS = ["SHENG_AUTOBRIGHTNESS_EMA", "SHENG_AUTOBRIGHTNESS_DEADBAND",
         "SHENG_AUTOBRIGHTNESS_MIN_INTERVAL", "SHENG_AUTOBRIGHTNESS_SETTLE",
         "SHENG_AUTOBRIGHTNESS_SETTLE_EPS", "SHENG_AUTOBRIGHTNESS_TOGGLE_POLL",
         "SHENG_AUTOBRIGHTNESS_USER_BIAS", "SHENG_AUTOBRIGHTNESS_MANUAL_TOL",
         "SHENG_AUTOBRIGHTNESS_WRITE_GRACE", "SHENG_AUTOBRIGHTNESS_READ_INTERVAL",
         "SHENG_AUTOBRIGHTNESS_MAX_OFFSET", "SHENG_AUTOBRIGHTNESS_BIAS_STEP",
         "SHENG_AUTOBRIGHTNESS_STATE"]


class FakeTime(object):
    def __init__(self):
        self.t = 1000.0

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s


class FakeStdout(object):
    def __init__(self, sim):
        self.sim = sim

    def readline(self):
        return "Light sensor measurement: %.1f Lux\n" % self.sim.lux


class FakeProc(object):
    def __init__(self, sim):
        self.stdout = FakeStdout(sim)

    def poll(self):
        return None

    def terminate(self):
        pass

    def wait(self, timeout=None):
        return 0


class Capture(object):
    def __init__(self):
        self.lines = []

    def write(self, s):
        self.lines.append(s.rstrip("\n"))

    def flush(self):
        pass


class Sim(object):
    """One scripted daemon run: 1 `select` timeout == 1 virtual second."""

    def __init__(self, lux, screen, state_file, lag=0):
        self.lux = lux
        self.screen = screen
        self.state_file = state_file
        self.lag = lag              # seconds before a write shows in the readback
        self.writes = []            # (virtual_t, pct)
        self.log = []
        self.tick = 0
        self.ticks = 0
        self.script = {}            # tick -> callable(sim)
        self.pending = []           # (tick_due, pct)
        self.ft = FakeTime()
        self.out_sig = "transform=0,scale=2.5,width=3048,height=2032,enabled=true"

    # ---- fake environment -------------------------------------------------
    def _select(self, rlist, wlist, xlist, timeout):
        self.tick += 1
        self.ft.t += 1.0
        due = [p for p in self.pending if p[0] <= self.tick]
        if due:
            self.pending = [p for p in self.pending if p[0] > self.tick]
            self.screen = due[-1][1]
        if self.tick > self.ticks:
            raise KeyboardInterrupt
        cb = self.script.get(self.tick)
        if cb:
            cb(self)
        return ([rlist[0]], [], [])

    def _set_brightness(self, pct):
        pct = max(1, min(100, int(pct)))
        self.writes.append((self.ft.t, pct))
        self.pending.append((self.tick + self.lag, pct))
        return True

    def _gs_get_bool(self, key):
        return True

    def _save(self, b):
        with open(self.state_file, "w") as f:
            f.write("offset=%.2f\n" % b)

    def _load(self):
        try:
            with open(self.state_file) as f:
                for line in f:
                    k, _, v = line.partition("=")
                    if k.strip() == "offset":
                        return float(v)
        except IOError:
            pass
        return 0.0

    def run(self, ticks, script=None, env=None):
        self.ticks = ticks
        self.script = script or {}
        for k in KNOBS:
            os.environ.pop(k, None)
        os.environ["SHENG_AUTOBRIGHTNESS_STATE"] = self.state_file
        for k, v in (env or {}).items():
            os.environ[k] = v

        name = "sheng_ab_%d" % id(self)
        spec = importlib.util.spec_from_file_location(
            name, DAEMON, loader=importlib.machinery.SourceFileLoader(name, DAEMON))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)

        m.time = self.ft
        m.select = type("S", (), {"select": staticmethod(self._select)})
        m.start_reader = lambda: FakeProc(self)
        m.output_signature = lambda: self.out_sig
        m.get_brightness = lambda: self.screen
        m.set_brightness = self._set_brightness
        m.gs_get_bool = self._gs_get_bool
        m.gs_set_bool = lambda k, v: None
        m.save_bias = self._save
        m.load_bias = self._load

        saved_argv, saved_err = sys.argv, sys.stderr
        cap = Capture()
        sys.argv = ["sheng-autobrightness", "--debug"]
        sys.stderr = cap
        try:
            try:
                m.main()
            except KeyboardInterrupt:
                pass
        finally:
            sys.argv, sys.stderr = saved_argv, saved_err
        self.log = cap.lines
        return self

    @property
    def bias(self):
        return self._load()


def report(title, sim, expect_writes=None, expect_bias=None, expect_screen=None,
           verbose=False):
    ok = True
    print("=" * 74)
    print(title)
    print("-" * 74)
    for t, p in sim.writes:
        print("   t=%7.1f  SET %d%%" % (t, p))
    for l in sim.log:
        if verbose or any(k in l for k in ("manual", "bias", "baseline")):
            print("   LOG  %s" % l)
    print("   final screen=%d%%  bias=%+.2f" % (sim.screen, sim.bias))
    if expect_writes is not None:
        got = [p for _, p in sim.writes]
        if got != expect_writes:
            print("   !! writes %s != expected %s" % (got, expect_writes))
            ok = False
    if expect_bias is not None and abs(sim.bias - expect_bias) > 0.01:
        print("   !! bias %+.2f != expected %+.2f" % (sim.bias, expect_bias))
        ok = False
    if expect_screen is not None and sim.screen != expect_screen:
        print("   !! screen %d != expected %d" % (sim.screen, expect_screen))
        ok = False
    print("   %s" % ("PASS" if ok else "FAIL"))
    return ok


def tmpstate(name):
    return os.path.join(tempfile.mkdtemp(prefix="abtest-"), name)


def t1_learn():
    """Startup applies the curve; a manual raise is learned as a bias."""
    s = Sim(lux=12.0, screen=42, state_file=tmpstate("a.conf"))
    s.run(30, script={8: lambda x: setattr(x, "screen", 45)})
    return report("[1] learn: curve gives 32, user drags to 45 -> bias +13",
                  s, expect_writes=[32], expect_bias=13, expect_screen=45)


def t2_carry():
    """The learned bias rides along when the light changes."""
    s = Sim(lux=12.0, screen=42, state_file=tmpstate("b.conf"))
    s.run(40, script={8: lambda x: setattr(x, "screen", 45),
                      25: lambda x: setattr(x, "lux", 200.0)},
          env={"SHENG_AUTOBRIGHTNESS_EMA": "1.0"})
    # lux 12 -> curve 32; user 45 -> bias +13; lux 200 -> curve 60 -> 73
    return report("[2] carry: bias +13 holds when lux 12 -> 200 (60+13=73)",
                  s, expect_writes=[32, 73], expect_bias=13, expect_screen=73)


def t3_no_snapback():
    """A persisted bias must not be undone at startup."""
    sf = tmpstate("c.conf")
    with open(sf, "w") as f:
        f.write("offset=13.00\n")
    s = Sim(lux=12.0, screen=45, state_file=sf)
    s.run(20)
    return report("[3] persisted bias +13: startup keeps 45 (32+13), no write",
                  s, expect_writes=[], expect_bias=13, expect_screen=45)


def t4_slow_readback():
    """A lagging readback after our own write must not become a phantom bias."""
    s = Sim(lux=12.0, screen=42, state_file=tmpstate("d.conf"), lag=2)
    s.run(25)
    return report("[4] 2s readback lag: no phantom bias, one write",
                  s, expect_writes=[32], expect_bias=0, expect_screen=32)


def t5_blip():
    """A single-tick blip (bus race) must not be learned."""
    s = Sim(lux=12.0, screen=42, state_file=tmpstate("e.conf"))

    def blip(x):
        x.screen = 80
        x.script[x.tick + 1] = lambda y: setattr(y, "screen", 32)
    s.run(30, script={10: blip})
    return report("[5] one-tick blip 80%% ignored -> bias stays 0",
                  s, expect_writes=[32], expect_bias=0)


def t6_reset_pickup():
    """A live `--reset-offset` (state file rewrite) must be picked up."""
    sf = tmpstate("f.conf")
    with open(sf, "w") as f:
        f.write("offset=15.00\n")
    s = Sim(lux=12.0, screen=47, state_file=sf)

    def reset(x):
        with open(sf, "w") as f:
            f.write("offset=0.00\n")
    s.run(30, script={20: reset})
    # Startup matches the on-screen 47 (=32+15) so nothing is written; the
    # reset then drops the bias to 0 and the daemon moves the screen to 32.
    return report("[6] live offset reset 15 -> 0 is picked up (47 -> 32)",
                  s, expect_writes=[32], expect_bias=0, expect_screen=32)


def t7_rotation_glitch():
    """The rotation glitch must not be learned, and must be corrected fast.

    Reproduces the measured on-device behaviour: after a display
    reconfiguration ukui-settings-daemon inflates the brightness (59 -> 92,
    or here 32 -> 65). The daemon must not latch that as the user bias and must
    put its own value back, bypassing SETTLE.
    """
    s = Sim(lux=12.0, screen=42, state_file=tmpstate("g.conf"))

    def reconfigure(x):
        x.out_sig = "transform=1,scale=2.5,width=2032,height=3048,enabled=true"
        x.screen = 65          # the usd glitch
    s.run(30, script={10: reconfigure})
    return report("[7] rotation glitch 32->65 is ignored and restored, bias kept",
                  s, expect_bias=0, expect_screen=32)


def t8_glitch_then_real_adjustment():
    """A genuine adjustment after the glitch window is still learned."""
    s = Sim(lux=12.0, screen=42, state_file=tmpstate("h.conf"))

    def reconfigure(x):
        x.out_sig = "transform=1,scale=2.5,width=2032,height=3048,enabled=true"
        x.screen = 65
    # glitch at t=10, then the user really sets 50 well after RECONF_WINDOW (5s)
    s.run(40, script={10: reconfigure, 25: lambda x: setattr(x, "screen", 50)})
    # 50 at lux 12 (curve 32) -> bias +18
    return report("[8] after the window, a real adjustment IS learned (+18)",
                  s, expect_bias=18, expect_screen=50)


if __name__ == "__main__":
    results = []
    for t in (t1_learn, t2_carry, t3_no_snapback, t4_slow_readback, t5_blip,
              t6_reset_pickup, t7_rotation_glitch, t8_glitch_then_real_adjustment):
        print()
        try:
            results.append((t.__name__, t()))
        except Exception as e:
            import traceback
            print("!! %s raised %s" % (t.__name__, e))
            traceback.print_exc()
            results.append((t.__name__, False))
    print()
    print("=" * 74)
    for n, ok in results:
        print("  %-20s %s" % (n, "PASS" if ok else "FAIL"))
    sys.exit(0 if all(ok for _, ok in results) else 1)
