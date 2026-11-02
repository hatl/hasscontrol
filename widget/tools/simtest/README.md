# Automated simulator tests

These scripts drive the Connect IQ simulator without a person at the keyboard: they push a build,
press the device's buttons, read the screen, and check what the widget sent to a mock Home Assistant.
46 scenarios over six devices cover the lock confirmation, Wi-Fi/LTE execution, the loopback-http
exception, the launch wait, the timer fix and the date/time editor. They have found five defects that
the compiler cannot see: the sync-mode crash, the truncated Wi-Fi/LTE question, the Wi-Fi/LTE
question hiding the value, the sensor-style values that were not persisted, and Back on the launch
wait closing the widget.

## Layout

The scripts expect a work directory with `harness/` (the Python), `scripts/` (the shell scripts and
the mock), `variants2/` (built `.prg` files) and `venv/` side by side; this folder is a flat copy of
`harness/` and `scripts/`. Set one up with:

```sh
mkdir -p ~/simtest/{harness,scripts,variants2} && cd ~/simtest
cp /path/to/widget/tools/simtest/*.py harness/ && cp /path/to/widget/tools/simtest/*.sh /path/to/widget/tools/simtest/mock_ha.py scripts/
python3 -m venv --system-site-packages venv && venv/bin/pip install python-xlib   # pillow, numpy from the system
```

The system needs `tesseract`, ImageMagick's `import`, `Xwayland`, `ss`, and a Connect IQ SDK (the
one in `~/.Garmin/ConnectIQ/current-sdk.cfg`) with the developer key at
`~/Programme/connectiq-sdk-manager/developer_key` (or `CIQ_KEY`).

## Running

```sh
scripts/mocks.sh start                        # mock Home Assistant on 8123 (http) and 8124 (https)
Xwayland :5 -geometry 1400x1000 -noreset &    # a display of its own, so your desktop is left alone
SRC=/path/to/widget scripts/build-variants2.sh   # settings variants for the old suite -> variants2/
SRC=/path/to/widget scripts/build-dt-variants.sh # the date/time variants
scripts/runall.sh                             # every device, one process per device
scripts/rundt.sh                              # only the date/time scenarios
scripts/retry-failures.sh f7_lock_pin_ok      # named scenarios, one process each
venv/bin/python harness/run.py fenix7x        # one device in one process (less robust, see below)
```

`run.py` writes `results/<scenario>/REPORT.md` with the checks, the screenshots, the app log and
`run.log`, and a `results/SUMMARY.md` over the scenarios of that invocation. `CIQ_VARIANTS=<dir>`
points a run at builds in another directory (`build-wt-variants.sh` builds the old-suite variants
from any tree into one). `mkvariant.sh` copies the widget sources and overrides property defaults in
`resources/properties.xml`; `build.sh` compiles one variant.

`explore.py <device> <variant> <steps...>` is the same machinery without assertions: it walks the
widget and dumps a screenshot, the OCR text, the app log and the mock traffic for every step. Use it
to see what a screen actually looks like before writing a check against it.

The mock (`mock_ha.py`) serves `group.garmin` (15 entities of every supported type) and
`group.datetime` (six date/time entities), implements the services the widget calls, and has control
endpoints under `/_test/`: `log`, `reset`, `state`, `set`, `fail` (make the next requests fail) and
`delay` (seconds added to every API request, so a loader stays on screen). `Mock` in `ciqsim.py`
wraps them.

## How it works, and what bites

The simulator runs on a private rootful Xwayland display, so the tests never touch the real desktop.
Everything below was learned the hard way; `ciqsim.py` carries the same notes at each method.

- **Keyboard arrows and Enter do not reach the app, but Escape does - as the BACK button.** Device
  buttons are pressed by clicking their hotspots on the device image, taken from
  `~/.Garmin/ConnectIQ/Devices/<device>/simulator.json`. Never dismiss a menu with Escape: the second
  one backs out of the widget. `close_menus()` clicks outside the window instead.
- **The device image is not centred** in the window, so the hotspots have to be located: `ciqsim`
  matches the bezel against the device PNG. Assuming it is centred puts the Enter press just outside
  its button, and the launch then fails silently.
- **Restarting the simulator races its own port.** Wait until nothing holds TCP 1234 in any state
  before starting a new one, or it never binds and hangs with an empty window. A simulator that
  inherits a `simulator.ini` with duplicate keys hangs behind a modal warning instead: the harness
  writes that file atomically and only while no simulator runs. Keys worth knowing: `BleState` and
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
  select confirms, back cancels.
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
