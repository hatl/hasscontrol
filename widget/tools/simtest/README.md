# Automated simulator tests

These scripts drive the Connect IQ simulator without a person at the keyboard: they push a build,
press the device's buttons, read the screen, and check what the widget sent to a mock Home Assistant.
55 scenarios over six devices cover the lock confirmation, Wi-Fi/LTE execution, the loopback-http
exception, the launch wait, the timer fix, the date/time editor, the entity storage and the glance. They have
found five defects that the compiler cannot see: the sync-mode crash, the truncated Wi-Fi/LTE
question, the Wi-Fi/LTE question hiding the value, the sensor-style values that were not persisted,
and Back on the launch wait closing the widget. `capacity.py` (below) found a sixth: the Out Of
Memory crash at the end of a refresh once a 64 KB watch holds some two dozen entities.

## Setup

Everything runs from this folder; nothing has to be copied anywhere. [uv](https://docs.astral.sh/uv/)
manages the Python environment (`pyproject.toml`: python-xlib, pillow, numpy; `uv run` creates
`.venv/` on first use). Besides uv the system needs `tesseract`, ImageMagick's `import`, `Xwayland`,
`ss`, `openssl`, `sway` (optional: it keeps the runs off your screen, see below), and a Connect IQ SDK (the one in `~/.Garmin/ConnectIQ/current-sdk.cfg`, or
`CIQ_SDK`) with the developer key at `~/Programme/connectiq-sdk-manager/developer_key` (or `CIQ_KEY`).

Everything a run produces goes under `work/` (gitignored; `CIQ_WORK` moves it): `work/variants2/`
holds the builds, `work/results/` the reports, `work/mock/` the mock servers' logs and their
self-signed certificate, `work/live/` the exploratory sessions, `work/capacity/` the capacity runs.
The mock servers and the private X display are started on demand and left running; stop them with
`./mocks.sh stop` and `./display.sh stop`.

## Exploratory testing by hand

```sh
uv run live.py                                  # fenix7x
uv run live.py venusq2 lockConfirmation=2 lockPin=1234
```

`live.py` starts the mocks, builds the widget from this tree with host, token and group pointed at
the mock (`group.all`, one entity of every supported type, date/time included; further `key=value`
arguments override settings from `resources/properties.xml`), **deletes every app with its settings
and storage from the simulator** (so stored settings of yours can never point the build at a real
Home Assistant), opens the simulator on your desktop and pushes the build. Down selects the widget
in the glance list, Enter opens it; the app's output streams to the terminal, Ctrl-C stops the app
and the simulator and lists what the widget sent to the mock. A 64 KB device gets a release build
against the TLS mock automatically. The mock's control endpoints (below) work meanwhile, e.g. to
change a state behind the widget's back.

## Automated runs

```sh
./build-all.sh                       # every build the run needs -> work/variants2/, work/out/
./runall.sh                          # every device, one process per device (about 50 minutes)
./runall.sh -j 6                     # six jobs side by side, each in a sandbox (about 15 minutes)
./rundt.sh [device ...]              # only the date/time scenarios
./retry-failures.sh f7_lock_pin_ok   # named scenarios, one process each
uv run run.py fenix7x                # one device in one process (less robust, see below)
uv run run.py f7_lock_pin_ok         # or scenarios by name or by feature
```

`build-all.sh` runs the three build scripts and fails when one build fails: `build-variants2.sh`
(the settings variants of the older scenarios; the `wifi*` ones against the TLS mock, because
Wi-Fi/LTE refuses plain http), `build-dt-variants.sh` (the date/time variants) and `build-master.sh`
(release 2.3.0 - the last one that stored the entity list as one array and knew none of the newer
settings - plain for the settings-upgrade scenario and pointed at the mock for the scenarios that
compare with it; `REF=v2.1.0 NAME=v210 ./build-master.sh` builds any other release the same way).

Only one simulator can exist on a machine: it listens on a fixed port, keeps its apps under one
folder in `/tmp` and takes any other simulator process for itself. `sandbox.sh <command>` runs a
command with a network, a `/tmp`, a process table and a simulator settings folder of its own
(bubblewrap, no root needed), and `runall.sh -j N` uses it to run N jobs at once - every device a
job, a device with many scenarios several (`CHUNK=8` scenarios each). Each job starts its own mocks,
X display and simulator; your own `simulator.ini` is not touched. A scenario that fails in such a
run is run once more on its own: with six simulators busy, a tap is lost now and then.
`capacity.py` and `retry-failures.sh` work under `sandbox.sh` too, e.g. two capacity runs at once.

`run.py` writes `work/results/<scenario>/REPORT.md` with the checks, the screenshots, the app log
and `run.log`, and `work/results/SUMMARY.md` over the scenarios of that invocation (the shell
wrappers keep a copy per device). `CIQ_VARIANTS=<dir>` points a run at builds in another directory
(`SRC=<widget dir> OUT=<dir> ./build-wt-variants.sh` builds the older scenarios' variants from any
tree into one, for comparing revisions). `mkvariant.sh` copies the widget sources and overrides
property defaults in `resources/properties.xml`; `build.sh` compiles one variant; `cleanup.sh` stops
stray runners, simulators and monkeydo processes.

### Capacity

```sh
uv run capacity.py instinct2x 12 18 24 28            # groups of n switches
uv run capacity.py instinct2x 24 --mixed             # every supported type, repeated up to n
uv run capacity.py instinct2x 24 --ref v2.3.0        # a build of that release instead of this tree
uv run capacity.py instinct2x 24 --first-ref v2.3.0  # 2.3.0 imports and stores, this tree takes over
```

How many entities a build holds on a device, and what happens beyond that. For every n the mock
gets a group of n entities, and a release build pointed at it goes through what a watch goes
through: a first launch (import, refresh, store), relaunches on the stored list, one toggle, a walk
through the list and a last relaunch. Per launch it records how many entities were refreshed,
whether the group had to be imported again (nothing was stored), the memory in use and any crash;
a table at the end gives one verdict per n. Run it on one 64 KB device and on `instincte45mm` (128 KB
with the full feature set, the smallest full-memory class) whenever a change adds code to the widget
or touches how entities are loaded, refreshed or stored: on these devices the build's own size is
what decides how many entities fit.

`uv run explore.py <device> <variant> <steps...>` is the automated machinery without assertions: it
walks the widget on the private display and dumps a screenshot, the OCR text, the app log and the
mock traffic for every step. Use it to see what a screen actually looks like before writing a check
against it.

The mock (`mock_ha.py`) serves `group.garmin` (15 entities of every supported type), `group.datetime`
(six date/time entities) and `group.all` (both, plus `number`, `select` and `input_button`),
implements the services the widget calls, and has control endpoints under `/_test/`: `log`,
`reset`, `state`, `set`, `fail` (make the next requests fail) and `delay` (seconds added to every API
request, so a loader stays on screen). `Mock` in `ciqsim.py` wraps them:

```sh
curl -s -X POST localhost:8123/_test/set -d '{"entity_id":"light.kitchen","state":"off"}'
curl -s localhost:8123/_test/log | python3 -m json.tool
```

## How it works, and what bites

The automated runs put the simulator on a private rootful Xwayland display (`:5`, `CIQ_DISPLAY`; started
by the harness when missing), so the tests never touch the keyboard, the mouse or the focus of the
real desktop. Nor do they show on it: Xwayland draws on a Wayland compositor, and on the desktop's own
its display is a window that comes up with every run - once per job with `runall.sh -j`. `display.sh`
therefore gives it a compositor of its own that shows nothing (`sway` on the wlroots headless
backend, its socket in `/tmp/ciq-display-<uid>-<display>`). To watch a run, stop the display and
start the run with `CIQ_SHOW=1`: the display is then a window on the desktop, as it is on a machine
without `sway`. `./display.sh` says which of the two is running.
Everything below was learned the hard way; `ciqsim.py` carries the same notes at each method.

- **Keyboard arrows and Enter do not reach the app, but Escape does - as the BACK button.** Device
  buttons are pressed by clicking their hotspots on the device image, taken from
  `~/.Garmin/ConnectIQ/Devices/<device>/simulator.json`. Never dismiss a menu with Escape: the second
  one backs out of the widget. `close_menus()` clicks outside the window instead.
- **The device image is not centred** in the window, so the hotspots have to be located: `ciqsim`
  matches the bezel against the device PNG. Assuming it is centred puts the Enter press just outside
  its button, and the launch then fails silently.
- **Restarting the simulator races its own port.** Wait until nothing holds TCP 1234 in any state
  before starting a new one, or it never binds and hangs with an empty window (whatever still holds
  it after a while - a monkeydo left over from an interrupted run - is killed). A simulator that
  inherits a `simulator.ini` with duplicate keys hangs behind a modal warning instead: the harness
  writes that file atomically and only while no simulator runs, and puts it back as it was when
  the run ends (`cleanup.sh` catches up after an interrupted one) - a run switches
  `UseHttpsRequirements` off, which your own sessions should not inherit. Keys worth knowing: `BleState` and
  `WifiState` (0 not initialised, 1 not connected, 2 connected), `TimeSetting` (the simulator
  defaults to the 12-hour clock; 24-hour scenarios set it to 1), and 32-hex-character keys that
  remember the device per app id and override `LastUsedDevice` (the harness drops them).
- **Release builds print nothing**, so a launch cannot be detected from the app log. The memory
  reading in the simulator's status bar can: the glance page runs on a much smaller budget than the
  widget.
- **Devices differ in how you select an entity.** Watches use the enter button; the Edge units have
  only START and LAP and neither selects - there the entity is tapped. Devices without up/down are
  scrolled by swiping. The vivoactive 3's button does not open the widget from its loop page; a tap
  does.
- **The Cancel/Confirm dialog shows no selection** and the down button does not move between the two:
  select confirms, back cancels. That is the system's `Confirmation`, which only the Wi-Fi/LTE
  question still uses (`Sim.confirm()`). The lock's question is a view of the widget's own, because
  a second press of select must not confirm it: `Sim.lock_answer()` moves the focus or taps a key,
  and `lock_focus()` reads which key has it.
- **The system pops a `ProgressBar` on back by itself**, even when a delegate's `onBack()` returns
  true. A loader delegate that pops as well takes the view beneath with it (the Back-on-wait
  defect). This is why `LoaderDelegate` and `ConnectionWaitDelegate` only clear state and return
  false.
- Menu items are found by OCR, so an exact match has to beat a substring - otherwise "Connected"
  selects "Not Connected" and the phone silently stays off. The BLE/WiFi state rows are picked by
  position, counting only rows with letters and merging rows within 8 px: the submenu's ">" arrow
  otherwise shows up as a row of its own on the Venu Sq 2.
- OCR misses small grey subtitles when the whole screen goes through tesseract at once; crop the
  header band instead (`header_text()`). The active field of the date/time editor (black on white)
  reads only when the box is inverted on its own; a boxed `55` otherwise reads as `59`, so
  `f7_dt_hold_release` compares pixels rather than digits.
- The mock cancels pending state transitions on reset, so a lock still settling from a previous
  scenario cannot leak into the next one.

## Known limitation

The simulator itself occasionally crashes (a SIGSEGV in GTK while opening its Settings submenu),
roughly once in a long session; the scenario running at that moment errors out and the next one
starts a fresh simulator. `runall.sh` runs each device in its own process and `retry-failures.sh`
one scenario per process, which keeps those sessions short; `run.py` also skips the between-scenario
phone reset when the phone is already connected, which halves the menu trips.

## Devices

`fenix7x` (round, touch, up/down), `venusq2` (rectangular, touch, no up/down, no Wi-Fi radio),
`edge1040` (Edge family, `:directwifi`), `fr255` (no touchscreen, so the PIN digit wheel and the
button flows), `instinct2x` and `vivoactive3` (both 64 KB `:lowmem`, the latter on Connect IQ 3.1.6).

Over Wi-Fi an Edge does its own TLS handshake and refuses the mock's self-signed certificate with
code 0 - the same failure the README warns about for real servers. Import over the phone first, then
switch Wi-Fi on. The simulator's clock follows the host machine's time zone; the `datetime.*`
scenarios compute their expected local times from it.
