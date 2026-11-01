# Automated simulator tests

These scripts drive the Connect IQ simulator without a person at the keyboard: they push a build,
press the device's buttons, read the screen, and check what the widget sent to a mock Home Assistant.
They were written to test the lock confirmation, Wi-Fi/LTE execution, the loopback-http exception,
the launch wait and the timer fix, and they found three defects that the compiler cannot.

## Running them

```sh
tools/simtest/mocks.sh start                 # mock Home Assistant on 8123 (http) and 8124 (https)
Xwayland :5 -geometry 1400x1000 -noreset &   # a display of its own, so your desktop is left alone
python3 tools/simtest/run.py                 # every scenario
python3 tools/simtest/run.py fenix7x         # one device
python3 tools/simtest/run.py f7_lock_pin_ok  # one scenario
```

`run.py` writes `results/<scenario>/REPORT.md` with the checks, the screenshots and the app log, and
a `results/SUMMARY.md` over all of them. Builds come from a `variants2/` directory of `.prg` files
named `<variant>-<device>.prg`; `mkvariant.sh` copies the widget sources and overrides the property
defaults in `resources/properties.xml`, and `build.sh` compiles one.

`explore.py <device> <variant> <steps...>` is the same machinery without assertions: it walks the
widget and dumps a screenshot, the OCR text, the app log and the mock traffic for every step. Use it
to see what a screen actually looks like before writing a check against it.

Python needs `python-xlib`, `pillow` and `numpy`; the system needs `tesseract`, ImageMagick's
`import`, and a Connect IQ SDK.

## How it works, and what bites

The simulator runs on a private rootful Xwayland display, so the tests never touch the real desktop.
Everything below was learned the hard way; `ciqsim.py` carries the same notes at each method.

- **Keyboard input does not reach the app.** Device buttons are pressed by clicking their hotspots on
  the device image, taken from `~/.Garmin/ConnectIQ/Devices/<device>/simulator.json`.
- **The device image is not centred** in the window, so the hotspots have to be located: `ciqsim`
  matches the bezel against the device PNG. Assuming it is centred puts the Enter press just outside
  its button, and the launch then fails silently.
- **Restarting the simulator races its own port.** Wait until nothing holds TCP 1234 in any state
  before starting a new one, or it never binds and hangs with an empty window.
- **Release builds print nothing**, so a launch cannot be detected from the app log. The memory
  reading in the simulator's status bar can: the glance page runs on a much smaller budget than the
  widget.
- **Devices differ in how you select an entity.** Watches use the enter button; the Edge units have
  only START and LAP and neither selects - there the entity is tapped. Devices without up/down are
  scrolled by swiping.
- **The Cancel/Confirm dialog shows no selection** and the down button does not move between the two:
  select confirms, back cancels.
- Menu items are found by OCR, so an exact match has to beat a substring - otherwise "Connected"
  selects "Not Connected" and the phone silently stays off.
- OCR misses small grey subtitles when the whole screen goes through tesseract at once; crop the
  header band instead (`header_text()`).
- The mock cancels pending state transitions on reset, so a lock still settling from a previous
  scenario cannot leak into the next one.

## Known limitation

Changing the phone's connection while the widget is already running is unreliable: the Settings
menu sometimes does not open, or the new state does not take, and the scenario then fails somewhere
later for a reason that has nothing to do with the widget. The four scenarios that need it
(`f7_connection_wait`, `f7_wifi_offer_and_cancel`, `f7_wifi_confirm_starts_sync`,
`vq_wifi_without_radio`) pass when they work, but may need a retry. Everything that sets the
connection state *before* pushing the app is stable.

The simulator also gets unreliable when one process restarts it many times, which is why
`runall.sh` runs each device in its own process and `retry-failures.sh` runs one scenario per
process.

## Devices

`fenix7x` (round, touch, up/down), `venusq2` (rectangular, touch, no up/down, no Wi-Fi radio),
`edge1040` (Edge family, `:directwifi`), `fr255` (no touchscreen, so the PIN digit wheel),
`instinct2x` and `vivoactive3` (both 64 KB `:lowmem`, the latter on Connect IQ 3.1.6).

Over Wi-Fi an Edge does its own TLS handshake and refuses the mock's self-signed certificate with
code 0 - the same failure the README warns about for real servers. Import over the phone first, then
switch Wi-Fi on.
