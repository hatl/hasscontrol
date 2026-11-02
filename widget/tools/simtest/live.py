#!/usr/bin/env python3
"""Open the simulator on your desktop with a HassControl build that talks to the mock Home Assistant,
for exploratory testing by hand: every supported entity type is in the group it imports.

    uv run live.py                       fenix7x
    uv run live.py venusq2 lockConfirmation=2 lockPin=1234
    uv run live.py fenix7x --release     a release build (no app log)

What it does, in order:
  1. starts the mock Home Assistant servers if they are not running (mocks.sh start),
  2. builds the widget from this folder's sources with host, token and group pointed at the mock
     (`group.all`: locks, covers, lights, ..., number/select, every date/time entity) plus any
     key=value setting overrides given on the command line -> work/live/<device>.prg,
  3. DELETES EVERY APP, ITS SETTINGS AND ITS STORAGE FROM THE SIMULATOR (so no stored settings of
     yours can point the build at a real Home Assistant), sets the device, phone "Connected", Wi-Fi
     "Not Connected" and the device HTTPS requirement off, and starts the simulator on your desktop,
  4. pushes the build with monkeydo and streams the app's output here.
Then it is yours: Down selects the widget in the glance list, Enter opens it.  Ctrl-C stops the
app and the simulator (--keep leaves the simulator running) and prints what the widget sent to the
mock.  The mocks keep running (mocks.sh stop).

The mock's control endpoints are handy meanwhile, e.g. to make the next request fail or to change a
state behind the widget's back:
    curl -s -X POST localhost:8123/_test/set -d '{"entity_id":"light.kitchen","state":"off"}'
    curl -s -X POST localhost:8123/_test/fail -d '{"code":500,"count":1}'
    curl -s localhost:8123/_test/log | python3 -m json.tool

--display :5 opens it on the harness's private X display instead (for a script to drive).
"""
import argparse
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ciqsim
from ciqsim import Sim, Mock, MOCK_HTTP, MOCK_HTTPS, LOWMEM, HERE, WORK, log


def sh(*cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device", nargs="?", default="fenix7x")
    ap.add_argument("overrides", nargs="*", help="setting overrides, key=value (see resources/properties.xml)")
    ap.add_argument("--release", action="store_true", help="release build (-r -O2); debug otherwise")
    ap.add_argument("--keep", action="store_true", help="leave the simulator running at the end")
    ap.add_argument("--display", default=None, help="X display to open the simulator on instead of your desktop")
    ap.add_argument("--group", default="all", help="the mock group to import (all, garmin, datetime)")
    a = ap.parse_args()
    for kv in a.overrides:
        if "=" not in kv:
            ap.error(f"not a key=value override: {kv!r}")

    lowmem = a.device in LOWMEM
    host = MOCK_HTTPS if lowmem else MOCK_HTTP      # 64 KB builds have no loopback-http exception
    if lowmem and not a.release:
        log(f"{a.device} is a 64 KB device: building release (a debug build does not fit)")
        a.release = True

    # 1. the mocks
    print(sh(os.path.join(HERE, "mocks.sh"), "start").stdout, end="")
    mock = Mock(host)
    mock.reset()

    # 2. the build
    widget = os.path.abspath(os.path.join(HERE, "..", ".."))
    src = os.path.join(WORK, "live", "src-" + a.device)
    prg = os.path.join(WORK, "live", a.device + ".prg")
    os.makedirs(os.path.dirname(prg), exist_ok=True)
    r = sh(os.path.join(HERE, "mkvariant.sh"), widget, src, f"host={host}", "accessToken=TESTTOKEN",
           f"group={a.group}", *a.overrides)
    if r.returncode:
        sys.exit("mkvariant failed:\n" + r.stdout + r.stderr)
    if os.path.exists(prg):
        os.remove(prg)
    log(f"building {a.device} ({'release' if a.release else 'debug'}) from {widget}")
    r = sh(os.path.join(HERE, "build.sh"), src, a.device, prg, "release" if a.release else "debug")
    if not os.path.exists(prg):
        sys.exit("build failed:\n" + r.stdout[-3000:])
    for line in r.stdout.splitlines():
        if "ERROR" in line or "WARNING" in line or "Total used" in line or "Code size" in line:
            print("  " + line.strip())

    # 3. the simulator, on the desktop this script was started from
    if a.display:
        ciqsim.DISPLAY = a.display
    sim = Sim(a.device, os.path.join(WORK, "live", "session"), attached=not a.display)
    print("\n*** Deleting every app, its settings and its storage from the simulator. ***\n")
    sim.start(wipe=True, https_requirements=False)
    log("simulator is up")

    # 4. push, then hand over
    sim.push(prg)
    # Ctrl-C (and a plain kill) end the session cleanly even when the shell started this in the
    # background with SIGINT ignored, as non-interactive shells do.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    print(f"\n{a.device}: pushed {os.path.basename(prg)}. Down selects the widget, Enter opens it. "
          f"Ctrl-C ends the session.\napp log: {sim.applog_path}\n")
    try:
        with open(sim.applog_path, "rb") as f:
            while True:
                chunk = f.read()
                if chunk:
                    sys.stdout.write(chunk.decode(errors="replace"))
                    sys.stdout.flush()
                elif sim.monkeydo and sim.monkeydo.poll() is not None:
                    log("monkeydo ended (the app was closed or the simulator went away)")
                    break
                else:
                    time.sleep(0.3)
    except KeyboardInterrupt:
        print()
    finally:
        try:
            reqs = mock.log()
        except Exception:
            reqs = []
        print(f"\n{len(reqs)} requests reached the mock" + (":" if reqs else "."))
        for e in reqs:
            body = e.get("body")
            print(f"  {e['method']} {e['path']}" + (f"  {body}" if body else ""))
        if a.keep:
            sim._stop_monkeydo()
            log("simulator left running")
        else:
            sim.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
