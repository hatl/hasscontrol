#!/usr/bin/env python3
"""ciqsim - drives the Connect IQ simulator for automated HassControl tests.

The simulator runs inside a rootful Xwayland server on DISPLAY :5 (a plain X11
display that only the tests use, so the user's keyboard, mouse and focus are
never touched).  Device buttons are pressed by clicking their hotspots on the
device image (positions from the SDK's simulator.json), touch by clicking
inside the display, screenshots via ImageMagick `import`, text via tesseract.

Typical use (see SCENARIO-GUIDE.md for the full story):

    from ciqsim import Sim, Mock, Report
    sim = Sim("fenix7x", "/path/to/results/A1")
    sim.start()                       # wipes the simulator's app files, starts the simulator
    sim.run(VARIANTS + "/closeauto-fenix7x.prg")   # push + launch, waits for the app's first output
    sim.wait_log(r"MEM init:7 done")
    sim.key("down"); sim.key("enter")  # device buttons (hotspots)
    sim.tap(140, 140)                  # touch, display coordinates
    path, img = sim.shot("after-toggle")
    text = sim.ocr(img)
    sim.menu("Settings", "Connection Type", "BLE", "Not Connected")
    sim.stop()

Everything is synchronous; one simulator at a time (port 1234).
"""
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
import ssl

from PIL import Image
import numpy as np
from Xlib import X, display as xdisplay, XK
from Xlib.ext import xtest

HERE = os.path.dirname(os.path.abspath(__file__))
# Everything a run produces - results, builds, mock logs, the Xwayland log - goes under one work
# directory next to these sources (gitignored); CIQ_WORK moves it elsewhere.  S is the older name.
WORK = os.environ.get("CIQ_WORK") or os.path.join(HERE, "work")
S = WORK
SDK = os.environ.get("CIQ_SDK") or open(os.path.expanduser("~/.Garmin/ConnectIQ/current-sdk.cfg")).read().strip()
DISPLAY = os.environ.get("CIQ_DISPLAY", ":5")
APPS = "/tmp/com.garmin.connectiq/GARMIN/APPS"
CRASH_LOG = APPS + "/LOGS/CIQ_LOG.YML"
INI = os.path.expanduser("~/.Garmin/ConnectIQ/simulator.ini")
DEVICES = os.path.expanduser("~/.Garmin/ConnectIQ/Devices")
# Where the .prg builds are taken from; CIQ_VARIANTS points a run at another set of builds (one directory
# per source revision), without the scenarios having to know.
VARIANTS = os.environ.get("CIQ_VARIANTS") or os.path.join(WORK, "variants2")
MOCK_HTTP = "http://127.0.0.1:8123"
MOCK_HTTPS = "https://127.0.0.1:8124"
MENUBAR_X = {"File": 18, "Settings": 72, "Simulation": 147, "Data Fields": 231, "adb Connection": 330, "Help": 411}
MENUBAR_Y = 13
IMAGE_TOP = 28          # the device image is drawn below the menu bar
APP_NAME = "APP"        # every variant is pushed as APP.prg -> MEDIA/APP.PRG, SETTINGS/APP.SET, DATA/APP.DAT


def log(msg):
    sys.stderr.write(time.strftime("%H:%M:%S ") + msg + "\n")
    sys.stderr.flush()


def ensure_display(geometry="1400x1000"):
    """Start the private rootful Xwayland display if nothing serves it yet.  It is left running (a
    cold start of the simulator is slow enough already); display.sh stops it.  Returns True when it
    was started here."""
    try:
        xdisplay.Display(DISPLAY).close()
        return False
    except Exception:
        pass
    log(f"starting Xwayland {DISPLAY}")
    os.makedirs(WORK, exist_ok=True)
    out = open(os.path.join(WORK, "xwayland.log"), "ab")
    subprocess.Popen(["Xwayland", DISPLAY, "-geometry", geometry, "-noreset"], stdout=out, stderr=out,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    end = time.time() + 15
    while time.time() < end:
        try:
            xdisplay.Display(DISPLAY).close()
            return True
        except Exception:
            time.sleep(0.25)
    raise RuntimeError(f"Xwayland {DISPLAY} did not come up (see {WORK}/xwayland.log)")


class Device:
    """Geometry of a simulated device: image, display rectangle, button hotspots."""

    def __init__(self, name):
        self.name = name
        base = os.path.join(DEVICES, name)
        self.sim = json.load(open(os.path.join(base, "simulator.json")))
        self.compiler = json.load(open(os.path.join(base, "compiler.json")))
        img = self.sim.get("image") or name + ".png"
        self.image_path = os.path.join(base, img)
        self.image = Image.open(self.image_path).convert("RGBA")
        d = self.sim["display"]["location"]
        self.display = (d["x"], d["y"], d["width"], d["height"])
        self.shape = self.sim["display"].get("shape")
        self.keys = {k["id"]: k["location"] for k in self.sim.get("keys", [])}
        # simulator.json's "isTouch" is the authoritative touchscreen flag (compiler.json has none)
        self.touch = bool(self.sim["display"].get("isTouch"))
        self.ciq = self.compiler.get("connectIQVersion")
        self.mem = {a.get("type"): a.get("memoryLimit") for a in self.compiler.get("appTypes", [])}
        # The simulator's status bar shows "<used>/<total>kB" of whatever is running.  The glance page
        # of the widget loop has a much smaller budget than the widget itself, so the total says which
        # of the two is on screen (see Sim.memory()/Sim.running()).
        self.glance_kb = (self.mem.get("glance") or 0) / 1024.0

    def has_key(self, key):
        return key in self.keys


class Mock:
    """Control the mock Home Assistant (mock_ha.py, started by mocks.sh)."""

    def __init__(self, base=MOCK_HTTP):
        self.base = base
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE

    def _call(self, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method="POST" if data is not None else "GET",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5, context=self.ctx) as r:
            return json.loads(r.read() or b"null")

    def reset(self):
        return self._call("/_test/reset", {})

    def log(self):
        return [e for e in self._call("/_test/log") if not e["path"].startswith("/_test")]

    def requests(self, since=0.0):
        return [e for e in self.log() if e["ts"] > since]

    def state(self, entity=None):
        st = self._call("/_test/state")
        return st[entity]["state"] if entity else st

    def set(self, entity, state, attributes=None):
        body = {"entity_id": entity, "state": state}
        if attributes:
            body["attributes"] = attributes
        return self._call("/_test/set", body)

    def fail(self, code, count=1):
        return self._call("/_test/fail", {"code": code, "count": count})

    def delay(self, seconds):
        """Answer every /api/ request `seconds` later (0 clears it, as does reset())."""
        return self._call("/_test/delay", {"seconds": seconds})

    def wait_request(self, pattern, timeout=15, since=0.0, method=None):
        """Wait until a request whose path matches `pattern` (regex) arrived after `since`."""
        end = time.time() + timeout
        while time.time() < end:
            for e in self.requests(since):
                if re.search(pattern, e["path"]) and (method is None or e["method"] == method):
                    return e
            time.sleep(0.5)
        return None


class Sim:
    def __init__(self, device, log_dir=None, attached=False):
        self.dev = Device(device)
        self.device = device
        # attached: the simulator is started on the user's own desktop for them to use (live.py), not
        # on the private X display - nothing here may then look for its window or click on it.
        self.attached = attached
        self.log_dir = log_dir or os.path.join(S, "results", time.strftime("%H%M%S"))
        os.makedirs(self.log_dir, exist_ok=True)
        self.shot_count = 0
        self.monkeydo = None
        self.applog_path = os.path.join(self.log_dir, "app.log")
        self.mock = Mock(MOCK_HTTPS if device in LOWMEM else MOCK_HTTP)
        self.mock_http = Mock(MOCK_HTTP)
        self.mock_https = Mock(MOCK_HTTPS)
        self._x = None
        self._win = None
        self._origin = None
        self.notes = []
        # The phone state this harness last set: by start() (ini) or a set_connection() that went through.
        # None when unknown.  run.py skips its reset when it is already "Connected" - every trip through
        # the Settings menu risks the simulator's GTK crash (SIGSEGV in gtk_widget_get_parent under
        # gtk_menu_popup_at_widget, seen five times in long sessions).
        self.ble_state = None

    # ------------------------------------------------------------------ X11
    @property
    def x(self):
        if self._x is None:
            self._x = xdisplay.Display(DISPLAY)
        return self._x

    def window(self, refresh=False):
        """The simulator's toplevel X window (cached)."""
        if self._win is not None and not refresh:
            try:
                self._win.get_geometry()
                return self._win
            except Exception:
                self._win = None
        root = self.x.screen().root
        atom = self.x.intern_atom("_NET_WM_NAME")
        pid_atom = self.x.intern_atom("_NET_WM_PID")
        want = getattr(self, "_pid", None)
        for c in root.query_tree().children:
            try:
                if c.get_attributes().map_state != X.IsViewable:
                    continue
                n = c.get_full_property(atom, 0)
                n = n.value.decode(errors="replace") if n else (c.get_wm_name() or "")
                if "CIQ Simulator" not in n:
                    continue
                if want is not None:
                    pid = c.get_full_property(pid_atom, 0)
                    if pid and pid.value[0] != want:
                        continue      # a previous instance that has not finished exiting
                self._win = c
                return c
            except Exception:
                continue
        return None

    def window_title(self):
        if self.attached:
            return None
        w = self.window(refresh=True)
        if not w:
            return None
        n = w.get_full_property(self.x.intern_atom("_NET_WM_NAME"), 0)
        return n.value.decode(errors="replace") if n else w.get_wm_name()

    def image_origin(self):
        """Top-left of the device image in root coordinates (centred below the menu bar; verified by a
        template match of the bezel when possible)."""
        if self._origin:
            return self._origin
        w = self.window(refresh=True)
        g = w.get_geometry()
        # The device image is centred horizontally and sits right below the menu bar.
        x0 = g.x + (g.width - self.dev.image.size[0]) // 2
        y0 = g.y + IMAGE_TOP
        found = self._locate_image()
        if found is None:
            log("warning: the device image could not be matched; falling back to centring, which is "
                "wrong on some devices - check that sleep mode and night mode are off")
        if found:
            if abs(found[0] - x0) > 6 or abs(found[1] - y0) > 6:
                log(f"bezel match {found} differs from centring ({x0},{y0}); trusting the match")
            x0, y0 = found
        self._origin = (x0, y0)
        log(f"image origin {self._origin} (window {g.x},{g.y} {g.width}x{g.height}, image {self.dev.image.size})")
        return self._origin

    def _locate_image(self):
        """Find the device image inside the simulator window by matching the bezel.

        The simulator draws the device PNG 1:1, so an exhaustive search over the few dozen possible
        offsets finds it exactly.  Only pixels outside the display rectangle are compared (the display
        itself shows the app and changes), and only opaque ones (the PNG has transparent corners)."""
        try:
            win = np.asarray(self.window_shot()).astype(np.int16)
            img = np.asarray(self.dev.image)
            ih, iw = img.shape[:2]
            wh, ww = win.shape[:2]
            if wh < ih or ww < iw:
                return None
            dx, dy, dw, dh = self.dev.display
            opaque = img[:, :, 3] > 250
            opaque[max(dy - 2, 0):dy + dh + 2, max(dx - 2, 0):dx + dw + 2] = False
            ys, xs = np.nonzero(opaque)
            if len(ys) < 200:
                return None
            step = max(len(ys) // 400, 1)          # a few hundred sample pixels are plenty
            ys, xs = ys[::step], xs[::step]
            ref = img[ys, xs, :3].astype(np.int16)
            best, best_off = None, None
            for oy in range(0, wh - ih + 1):
                for ox in range(0, ww - iw + 1):
                    diff = int(np.abs(win[ys + oy, xs + ox] - ref).sum())
                    if best is None or diff < best:
                        best, best_off = diff, (ox, oy)
            if best is None:
                return None
            per_px = best / float(len(ys) * 3)
            g = self.window(refresh=True).get_geometry()
            log(f"bezel match at {best_off} (mean diff {per_px:.1f} per channel)")
            if per_px > 12:
                return None
            return (g.x + best_off[0], g.y + best_off[1])
        except Exception as e:
            log(f"locate image failed: {e}")
            return None

    def display_origin(self):
        x0, y0 = self.image_origin()
        return (x0 + self.dev.display[0], y0 + self.dev.display[1])

    def display_size(self):
        return (self.dev.display[2], self.dev.display[3])

    # ------------------------------------------------------------------ input
    def _button(self, x, y, hold_ms=120, button=1):
        root = self.x.screen().root
        root.warp_pointer(x, y)
        self.x.sync()
        time.sleep(0.08)
        xtest.fake_input(self.x, X.ButtonPress, button)
        self.x.sync()
        time.sleep(hold_ms / 1000.0)
        xtest.fake_input(self.x, X.ButtonRelease, button)
        self.x.sync()

    def move(self, x, y):
        self.x.screen().root.warp_pointer(x, y)
        self.x.sync()
        time.sleep(0.4)

    def click_root(self, x, y, hold_ms=120):
        self._button(x, y, hold_ms)
        time.sleep(0.3)

    def key(self, name, hold_ms=120, settle=0.6):
        """Press a device button by its hotspot: enter, esc, up, down, menu (fenix: hold of up), start, lap..."""
        if name == "menu" and "menu" in self.dev.keys and self.dev.keys["menu"] == self.dev.keys.get("up"):
            hold_ms = max(hold_ms, 1200)   # menu is a long press of the up button on these watches
        if name not in self.dev.keys:
            raise KeyError(f"{self.device} has no key {name!r}; keys: {sorted(self.dev.keys)}")
        loc = self.dev.keys[name]
        x0, y0 = self.image_origin()
        cx = x0 + loc["x"] + loc["width"] // 2
        cy = y0 + loc["y"] + loc["height"] // 2
        self._button(cx, cy, hold_ms)
        log(f"key {name} ({hold_ms} ms)")
        time.sleep(settle)

    def key_hold(self, name, ms=1200):
        self.key(name, hold_ms=ms)

    def xkey(self, keysym, hold_ms=100, settle=0.5):
        """Keyboard fallback (XTEST): keysym name such as 'Return', 'Escape', 'Down', 'Up'."""
        w = self.window()
        self.x.set_input_focus(w, X.RevertToParent, X.CurrentTime)
        code = self.x.keysym_to_keycode(XK.string_to_keysym(keysym))
        xtest.fake_input(self.x, X.KeyPress, code)
        self.x.sync()
        time.sleep(hold_ms / 1000.0)
        xtest.fake_input(self.x, X.KeyRelease, code)
        self.x.sync()
        time.sleep(settle)

    def tap(self, x, y, hold_ms=100, settle=0.6):
        """Touch the display at display coordinates (x, y)."""
        ox, oy = self.display_origin()
        self._button(ox + x, oy + y, hold_ms)
        log(f"tap ({x},{y})")
        time.sleep(settle)

    def long_press(self, x, y, ms=1200):
        self.tap(x, y, hold_ms=ms)

    def swipe(self, x1, y1, x2, y2, ms=300, steps=8):
        ox, oy = self.display_origin()
        root = self.x.screen().root
        root.warp_pointer(ox + x1, oy + y1)
        self.x.sync()
        time.sleep(0.05)
        xtest.fake_input(self.x, X.ButtonPress, 1)
        self.x.sync()
        for i in range(1, steps + 1):
            root.warp_pointer(ox + x1 + (x2 - x1) * i // steps, oy + y1 + (y2 - y1) * i // steps)
            self.x.sync()
            time.sleep(ms / 1000.0 / steps)
        xtest.fake_input(self.x, X.ButtonRelease, 1)
        self.x.sync()
        log(f"swipe ({x1},{y1})->({x2},{y2})")
        time.sleep(0.6)

    def find_on_display(self, label):
        """Locate `label` on the watch display; returns display coordinates or None."""
        ox, oy = self.display_origin()
        w, h = self.display_size()
        pos = self.find_text(label, region=(ox, oy, w, h))
        return None if pos is None else (pos[0] - ox + (0), pos[1] - oy)

    def select(self):
        """Press the device's select control.

        Watches use the enter button.  The Edge units have only START and LAP, and neither selects an
        entity - there the entity is tapped, as on the real head unit."""
        if self.dev.has_key("enter"):
            self.key("enter")
        elif self.dev.touch:
            w, h = self.display_size()
            self.tap(w // 2, h // 2)
        elif self.dev.has_key("start"):
            self.key("start")
        else:
            raise RuntimeError(f"{self.device}: no way to select")

    def back(self):
        if self.dev.has_key("esc"):
            self.key("esc")
        elif self.dev.has_key("lap"):
            self.key("lap")
        elif self.dev.touch:
            w, h = self.display_size()
            self.swipe(int(w * 0.15), h // 2, int(w * 0.85), h // 2)
        else:
            raise RuntimeError(f"{self.device}: no way to go back")

    def next_page(self):
        """Move to the next entity: the down button, or a swipe up on watches without one
        (Venu Sq, Edge, vivoactive)."""
        if self.dev.has_key("down"):
            self.key("down")
        elif self.dev.touch:
            w, h = self.display_size()
            self.swipe(w // 2, int(h * 0.72), w // 2, int(h * 0.28))
        else:
            raise RuntimeError(f"{self.device}: no way to scroll")

    def confirm(self, yes=True):
        """Answer a Cancel/Confirm dialog.

        The dialog draws no visible selection and the down button does not move between the two
        options: the select button confirms and the back button cancels, which is also what a tap on
        the respective word does."""
        if yes:
            self.select()
        else:
            self.back()
        log(f"confirm({yes})")
        time.sleep(1.0)

    # ------------------------------------------------------------------ PIN entry
    # The geometry below mirrors PinEntryView.drawKeypad() exactly, so the taps land where the view
    # looks for them (see widget/source/Lock/PinEntryView.mc).
    def keypad_geometry(self):
        w, h = self.display_size()
        top = h * 0.36
        bottom = h * (0.98 if self.dev.shape == "rectangle" else 0.93)
        cell_h = (bottom - top) / 4
        cell_w = min(w * 0.24, cell_h * 1.6)
        return (w / 2 - cell_w * 1.5, top, cell_w, cell_h)

    def keypad_cell(self, cell):
        """Centre of keypad cell 0-11 in display coordinates (cells 0-8 are 1-9, 9 blank/cancel,
        10 is 0, 11 delete)."""
        left, top, cw, ch = self.keypad_geometry()
        row, col = divmod(cell, 3)
        return (int(left + (col + 0.5) * cw), int(top + (row + 0.5) * ch))

    def digit_cell(self, digit):
        return self.keypad_cell(10 if digit == 0 else digit - 1)

    def tap_digit(self, digit):
        self.tap(*self.digit_cell(digit), settle=0.4)

    def tap_delete(self):
        self.tap(*self.keypad_cell(11), settle=0.4)

    def tap_cancel(self):
        self.tap(*self.keypad_cell(9), settle=0.4)

    def enter_pin(self, pin, settle=0.5):
        """Enter a PIN the way the device offers it: tapping the keypad on touch screens, rolling the
        digit wheel with up/down and confirming each digit with select on button watches."""
        for ch in str(pin):
            d = int(ch)
            if self.dev.touch:
                self.tap_digit(d)
            else:
                # the wheel starts at 0 and returns to 0 after every digit
                ups, downs = d, (10 - d) % 10
                key, count = ("up", ups) if ups <= downs else ("down", downs)
                for _ in range(count):
                    self.key(key, settle=0.25)
                self.key("enter", settle=0.4)
        time.sleep(settle)

    def pin_slots_filled(self):
        """How many of the four PIN slots are filled.

        PinEntryView draws the slots at 29 % of the height with radius 2.2 %: entered ones are discs,
        the next one an outline of pen width 3 and the rest thin outlines.  Measured over a band
        exactly one circle tall, a disc covers ~0.84 of its bounding box, the ringed slot ~0.62 and a
        plain outline ~0.33, so 0.72 separates filled from not."""
        w, h = self.display_size()
        r = max(int(h * 0.022), 4)
        y = int(h * 0.29)
        band = np.asarray(self.display_shot().convert("L"))[max(y - r, 0):y + r + 1, :] > 160
        cols = band.sum(axis=0)
        filled, start = 0, None
        for i, v in enumerate(list(cols) + [0]):
            if v > 0 and start is None:
                start = i
            elif v == 0 and start is not None:
                if i - start > 2:
                    sub = band[:, start:i]
                    if sub.sum() / float(sub.shape[0] * sub.shape[1]) > 0.72:
                        filled += 1
                start = None
        return filled

    def header_text(self):
        """The top of the screen (title and subtitle) read on its own - small grey subtitles are lost
        when the whole display goes through OCR in one piece."""
        w, h = self.display_size()
        img = self.display_shot().crop((0, 0, w, int(h * 0.28)))
        return self.ocr(img, scale=6, psm=6)

    # ------------------------------------------------------------------ screen
    def root_shot(self):
        out = subprocess.run(["import", "-display", DISPLAY, "-window", "root", "png:-"], capture_output=True, timeout=20)
        return Image.open(io.BytesIO(out.stdout)).convert("RGB")

    def window_shot(self):
        g = self.window(refresh=True).get_geometry()
        return self.root_shot().crop((g.x, g.y, g.x + g.width, g.y + g.height))

    def display_shot(self):
        ox, oy = self.display_origin()
        w, h = self.display_size()
        return self.root_shot().crop((ox, oy, ox + w, oy + h))

    def shot(self, name="shot", full=False):
        """Save a screenshot of the display (or the whole simulator window with full=True); returns (path, image)."""
        self.shot_count += 1
        img = self.window_shot() if full else self.display_shot()
        path = os.path.join(self.log_dir, f"{self.shot_count:03d}-{name}.png")
        img.save(path)
        log(f"shot {path}")
        return path, img

    def signature(self):
        """A cheap fingerprint of the display, to tell whether the screen changed."""
        img = self.display_shot().resize((32, 32))
        return tuple(np.asarray(img.convert("L")).flatten() // 32)

    def changed_from(self, sig, tolerance=12):
        """True when the display differs from the signature `sig` in more than `tolerance` cells."""
        now = self.signature()
        return sum(1 for a, b in zip(now, sig) if a != b) > tolerance

    @staticmethod
    def _prep_ocr(img, scale):
        """Upscale, and when the image is light text on a dark ground, invert it: tesseract is trained
        on dark text on white, and the watch screens are the other way round."""
        g = img.convert("L")
        big = g.resize((g.size[0] * scale, g.size[1] * scale), Image.LANCZOS)
        a = np.asarray(big)
        if a.mean() < 128:
            a = 255 - a
        a = np.where(a > 150, 255, 0).astype(np.uint8)
        return Image.fromarray(a)

    def ocr(self, img=None, scale=4, psm=6):
        """Text on the display (or of the given image/path) via tesseract."""
        if img is None:
            img = self.display_shot()
        elif isinstance(img, str):
            img = Image.open(img)
        big = self._prep_ocr(img, scale)
        buf = io.BytesIO()
        big.save(buf, format="PNG")
        out = subprocess.run(["tesseract", "stdin", "stdout", "--psm", str(psm)], input=buf.getvalue(),
                             capture_output=True, timeout=60)
        return out.stdout.decode(errors="replace").strip()

    def text(self):
        return self.ocr()

    def wait_text(self, pattern, timeout=10, interval=1.0):
        """Poll the display until its OCR text matches `pattern` (regex, case-insensitive)."""
        end = time.time() + timeout
        txt = ""
        while time.time() < end:
            txt = self.ocr()
            if re.search(pattern, txt, re.I | re.S):
                return True, txt
            time.sleep(interval)
        return False, txt

    def status_text(self):
        """The simulator's status bar (bottom of the window): memory use and the last touch position."""
        g = self.window(refresh=True).get_geometry()
        img = self.root_shot().crop((g.x, g.y + g.height - 24, g.x + g.width, g.y + g.height))
        return self.ocr(img, scale=4, psm=7)

    def memory(self):
        """(used_kb, total_kb) from the simulator's status bar, or (None, None) if it cannot be read."""
        m = re.search(r"([0-9]+[.,][0-9]|[0-9]+)\s*/\s*([0-9]+[.,][0-9]|[0-9]+)\s*k", self.status_text(), re.I)
        if not m:
            return (None, None)
        return tuple(float(v.replace(",", ".")) for v in m.groups())

    def wait_memory(self, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            used, total = self.memory()
            if total:
                return used, total
            time.sleep(0.5)
        return (None, None)

    def _ocr_boxes(self, img, scale=2):
        """Word boxes (tesseract tsv) of img, grouped into lines -> list of (text, x, y, w, h) in img coordinates."""
        big = self._prep_ocr(img, scale)
        buf = io.BytesIO()
        big.save(buf, format="PNG")
        out = subprocess.run(["tesseract", "stdin", "stdout", "--psm", "11", "tsv"], input=buf.getvalue(),
                             capture_output=True, timeout=60)
        lines = {}
        for row in out.stdout.decode(errors="replace").splitlines()[1:]:
            f = row.split("\t")
            if len(f) < 12 or not f[11].strip():
                continue
            try:
                conf = float(f[10])
            except ValueError:
                continue
            if conf < 30:
                continue
            key = (f[2], f[3], f[4])  # block, par, line
            x, y, w, h = int(f[6]) // scale, int(f[7]) // scale, int(f[8]) // scale, int(f[9]) // scale
            lines.setdefault(key, []).append((f[11], x, y, w, h))
        res = []
        for words in lines.values():
            words.sort(key=lambda t: t[1])
            text = " ".join(w[0] for w in words)
            x = min(w[1] for w in words)
            y = min(w[2] for w in words)
            x2 = max(w[1] + w[3] for w in words)
            y2 = max(w[2] + w[4] for w in words)
            res.append((text, x, y, x2 - x, y2 - y))
        return res

    def find_text(self, label, region=None, img=None):
        """Locate `label` (case-insensitive substring) in the root screenshot; returns (cx, cy) or None."""
        img = img or self.root_shot()
        rx, ry = 0, 0
        if region:
            rx, ry, rw, rh = region
            img = img.crop((rx, ry, rx + rw, ry + rh))
        norm = re.sub(r"\s+", " ", label).strip().lower()
        exact, partial = None, None
        for text, x, y, w, h in self._ocr_boxes(img):
            got = re.sub(r"\s+", " ", text).strip().lower()
            centre = (rx + x + w // 2, ry + y + h // 2)
            if got == norm and exact is None:
                exact = centre
            elif norm in got and partial is None:
                partial = centre
        # An exact match wins: "Connected" is a substring of "Not Connected", and picking the wrong
        # one silently leaves the phone disconnected.
        return exact or partial

    # ------------------------------------------------------------------ simulator menus
    def menu(self, *path, hover_last=False):
        """Open a simulator menu and click its item, e.g. menu("File", "Kill App") or
        menu("Settings", "Connection Type", "BLE", "Not Connected").  Intermediate items are hovered
        (they open submenus), the last one is clicked (or hovered with hover_last=True)."""
        top = path[0]
        self.click_root(MENUBAR_X[top], MENUBAR_Y)
        time.sleep(0.7)
        px, py = MENUBAR_X[top], MENUBAR_Y
        for i, label in enumerate(path[1:]):
            last = i == len(path) - 2
            region = (max(px - 30, 0), 0, 900, 1000)   # the (sub)menu opens to the right of the parent item
            pos = self.find_text(label, region=region)
            if not pos:
                self.shot(f"menu-fail-{label.replace(' ', '_')}", full=True)
                self.click_root(1300, 950)   # close the menus
                raise RuntimeError(f"menu item {label!r} not found under {' > '.join(path[:i + 1])}")
            if last and not hover_last:
                self.click_root(*pos)
            else:
                self.move(*pos)
                time.sleep(0.6)
            px, py = pos
        log("menu " + " > ".join(path))
        time.sleep(0.5)

    def close_menus(self):
        """Dismiss any open menu by clicking far away from everything (outside the simulator window),
        twice in case a submenu was open.

        No Escape key: with no menu open, XTEST keys do reach the device - the first Escape only takes
        the focus, the second arrives as BACK, and BACK on the entity view closes the widget.  This
        ran before every Settings > Connection Type change, so switching the phone while the widget
        ran closed it (the "known limitation" of the phone-changing scenarios)."""
        for _ in range(2):
            self.click_root(1300, 950)
            time.sleep(0.3)

    CONNECTION_STATES = ["Not Initialized", "Not Connected", "Connected"]

    def set_connection(self, kind, state, attempts=3):
        """Set BLE or Wi-Fi to one of Not Initialized / Not Connected / Connected.

        The state is chosen by its row, not by its label.  "Connected" is a substring of "Not
        Connected", and OCR sometimes reads "Not Initialized" as just "Not", so matching on text
        picks the wrong row or none at all - and a wrongly set phone state makes a scenario fail
        somewhere else entirely.  Hovering a submenu open does not always take on the first try, so
        the whole interaction is retried."""
        index = self.CONNECTION_STATES.index(state)
        last = None
        for attempt in range(attempts):
            try:
                self.close_menus()
                self.menu("Settings", "Connection Type", hover_last=True)
                ble = self.find_text("BLE")
                if ble is None:
                    raise RuntimeError("the BLE row was not found")
                row = ble if kind == "BLE" else (ble[0], ble[1] + self.MENU_ROW_HEIGHT)
                self.move(*row)
                time.sleep(1.2)
                # the states open in a column to the right of the row being hovered.  Only words
                # count: OCR also returns the submenu's ">" arrow, a pixel off the first state's
                # line - as a row of its own it shifted every index by one, and "Connected"
                # clicked "Not Connected" (seen on the Venu Sq 2).  Boxes within 8 px are one row.
                boxes = [(y, x) for t, x, y, w, h in self._ocr_boxes(self.root_shot())
                         if x > ble[0] + 80 and row[1] - 60 < y < row[1] + 110
                         and re.search(r"[A-Za-z]{3}", t)]
                ys = []
                for y in sorted({y for y, _ in boxes}):
                    if not ys or y - ys[-1] > 8:
                        ys.append(y)
                if len(ys) < 3:
                    raise RuntimeError(f"the {kind} states did not open (found {len(ys)} rows)")
                x = min(x for y, x in boxes if abs(y - ys[index]) <= 8)
                self.click_root(x + 30, ys[index])
                time.sleep(0.8)
                log(f"{kind} -> {state}")
                if kind == "BLE":
                    self.ble_state = state
                return
            except RuntimeError as e:
                last = e
                log(f"{kind} -> {state} failed ({e}); attempt {attempt + 1} of {attempts}")
                self.close_menus()
                time.sleep(1.0)
        if kind == "BLE":
            self.ble_state = None
        self.shot(f"connection-menu-{kind}", full=True)
        raise RuntimeError(f"could not set {kind} to {state}: {last}")

    def set_phone(self, connected):
        self.set_connection("BLE", "Connected" if connected else "Not Connected")

    def set_ble(self, state):
        """state: 'Connected' | 'Not Connected' | 'Not Initialized'"""
        self.set_connection("BLE", state)

    MENU_ROW_HEIGHT = 25      # vertical pitch of the simulator's menu items

    def wifi_supported(self):
        """Does this device model have a Wi-Fi radio?

        The simulator labels the entry "WiFi (Not Supported)" and greys it out when it has none.  OCR
        of that greyed label is not dependable and a disabled row still sits next to BLE's submenu, so
        the row's text colour decides: enabled items are drawn near-black, disabled ones mid-grey.
        On a device without the radio the Wi-Fi/LTE setting can do nothing."""
        if getattr(self, "_wifi_supported", None) is None:
            self.menu("Settings", "Connection Type", hover_last=True)
            ble = self.find_text("BLE")
            darkness = None
            if ble:
                root = np.asarray(self.root_shot().convert("L"))
                y = ble[1] + self.MENU_ROW_HEIGHT
                row = root[max(y - 7, 0):y + 8, max(ble[0] - 25, 0):ble[0] + 160]
                darkness = int(row.min()) if row.size else None
            self.close_menus()
            time.sleep(0.5)
            self._wifi_supported = darkness is not None and darkness < 100
            log(f"{self.device}: wifi row darkness {darkness} -> supported={self._wifi_supported}")
        return self._wifi_supported

    def set_wifi(self, state):
        """state: 'Connected' | 'Not Connected' | 'Not Initialized' (Settings > Connection Type > WiFi)."""
        self.set_connection("WiFi", state)

    def kill_app(self):
        if self.window(refresh=True):
            try:
                self.menu("File", "Kill App")
            except RuntimeError as e:
                log(str(e))
        self._stop_monkeydo()

    # ------------------------------------------------------------------ lifecycle
    def _ini(self, **kv):
        """Set keys in the simulator's ini file.

        Written atomically and only while no simulator runs: the simulator rewrites this file on
        exit, and interleaving with it corrupts lines and leaves duplicate keys - which the
        simulator then reports in a modal warning ("entry 'X' appears more than once in group"),
        where it sits forever without opening its port.  Duplicates already in the file are dropped,
        keeping the last value."""
        lines = open(INI).read().splitlines() if os.path.exists(INI) else []
        # Entries keyed by a 32-character application id remember which device each app was last
        # run on, and the simulator prefers them over LastUsedDevice - which is how it kept coming
        # back as the previous device no matter what was written here.
        lines = [l for l in lines if not re.match(r"^[0-9A-Fa-f]{32}=", l)]
        out, index = [], {}
        for ln in lines:
            if "=" not in ln:
                out.append(ln)
                continue
            k = ln.split("=", 1)[0]
            value = f"{k}={kv[k]}" if k in kv else ln
            if k in index:
                out[index[k]] = None          # an earlier duplicate of this key
            index[k] = len(out)
            out.append(value)
        for k, v in kv.items():
            if k not in index:
                out.append(f"{k}={v}")
        tmp = f"{INI}.{os.getpid()}.tmp"   # unique, so two runs cannot clobber each other
        with open(tmp, "w") as f:
            f.write("\n".join(l for l in out if l is not None) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, INI)

    def wipe_apps(self, keep_data=False):
        """Delete the simulator's installed apps, their settings and (unless keep_data) their storage."""
        for sub, pats in (("MEDIA", ["*.PRG"]), ("SETTINGS", ["*.SET"]), ("DATA", [] if keep_data else ["*.DAT", "*.IDX"])):
            d = os.path.join(APPS, sub)
            if not os.path.isdir(d):
                continue
            for f in os.listdir(d):
                if any(re.fullmatch(p.replace("*", ".*"), f) for p in pats):
                    os.remove(os.path.join(d, f))

    def start(self, wipe=True, keep_data=False, https_requirements=False, timeout=90, attempt=0):
        """Start the simulator preset to this device (restarts it if running).  wipe=True removes installed
        apps/settings (always do this at the start of a session - the user's own settings must never be used)."""
        self.stop()
        time.sleep(1.0)        # let a simulator that is on its way out finish writing the ini
        if wipe:
            self.wipe_apps(keep_data=keep_data)
        # SleepMode and nightMode change how the screen is drawn, which breaks both the bezel match
        # and the OCR; a stray click in the Settings menu can switch them on, so they are forced off
        # at every start along with the device and the connection state.
        # BleState/WifiState are 0 = Not Initialized, 1 = Not Connected, 2 = Connected.  Wi-Fi
        # starts at "Not Connected" so the radio exists without having to go through the menu -
        # a menu click that quietly misses would otherwise leave devices looking like they have no
        # Wi-Fi at all, and the Wi-Fi scenarios would test the wrong thing.
        # Write the settings and make sure they stuck: a simulator on its way out rewrites this
        # file, and if its copy wins the next one comes up as the previous device.
        for _ in range(5):
            self._ini(LastUsedDevice=self.device, UseHttpsRequirements=1 if https_requirements else 0,
                      BleState=2, SleepMode=0, nightMode=0, WifiState=1,
                      WindowX=0, WindowY=0)
            time.sleep(0.6)
            current = dict(l.split("=", 1) for l in open(INI).read().splitlines() if "=" in l)
            if current.get("LastUsedDevice") == self.device:
                break
            log("the simulator rewrote its settings; writing them again")
        os.makedirs(self.log_dir, exist_ok=True)
        env = dict(os.environ)
        if not self.attached:
            ensure_display()
            env.pop("WAYLAND_DISPLAY", None)
            env["DISPLAY"] = DISPLAY
            env["GDK_BACKEND"] = "x11"
        simlog = open(os.path.join(self.log_dir, "simulator.log"), "ab")
        self._pid = None
        proc = subprocess.Popen([os.path.join(SDK, "bin", "simulator")], env=env, stdout=simlog,
                                stderr=simlog, stdin=subprocess.DEVNULL, start_new_session=True,
                                cwd=self.log_dir)
        self._pid = proc.pid
        self._proc = proc
        # A simulator that could not bind port 1234 never recovers: it sits there with an empty
        # window for as long as you let it, so it is killed and started again.  The budget has to
        # stay generous even so - a healthy cold start can take the better part of a minute, and
        # killing those instead produces exactly the instability it is meant to avoid.
        end = time.time() + timeout
        while time.time() < end:
            if proc.poll() is not None:
                log(f"the simulator exited immediately (status {proc.returncode})")
                break
            if self._port_listening() and (self.attached or self.window(refresh=True)):
                break
            time.sleep(0.5)
        else:
            if attempt < 3:
                log(f"simulator did not open its port within {timeout} s; killing it and retrying")
                self.stop()
                return self.start(wipe=False, keep_data=keep_data, https_requirements=https_requirements,
                                  timeout=timeout, attempt=attempt + 1)
            raise RuntimeError("simulator did not come up (port 1234 never opened)")
        time.sleep(2.5)
        self._origin = None
        self.ble_state = "Connected"          # BleState=2, written above
        # The title names the device only once an app has been pushed, so it is checked in push().
        log(f"simulator up: {self.window_title()}")
        return self

    def _port_listening(self):
        """Is port 1234 open - by the simulator this object started, when it knows its pid?  A listener
        of another process is a leftover, never ours."""
        out = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True).stdout
        for ln in out.splitlines()[1:]:
            if ":1234" in ln and (self._pid is None or f"pid={self._pid}," in ln):
                return True
        return False

    @staticmethod
    def _simulator_pids():
        """Running simulator processes, skipping zombies - a defunct one can never be killed and
        would otherwise keep stop() waiting forever."""
        out = subprocess.run(["ps", "-eo", "pid,stat,comm"], capture_output=True, text=True).stdout
        pids = []
        for line in out.splitlines()[1:]:
            f = line.split(None, 2)
            if len(f) == 3 and f[2].strip() == "simulator" and not f[1].startswith("Z"):
                pids.append(f[0])
        return pids

    def stop(self, wait_port=True):
        """Stop monkeydo and every simulator.  wait_port: block until port 1234 is free again, which
        the next start() needs - a session that is ending anyway (live.py) skips the wait."""
        self._stop_monkeydo()
        pids = self._simulator_pids()
        for p in pids:
            try:
                os.kill(int(p), signal.SIGTERM)
            except ProcessLookupError:
                pass
        end = time.time() + 10
        while time.time() < end and self._simulator_pids():
            time.sleep(0.3)
        for p in self._simulator_pids():
            try:
                os.kill(int(p), signal.SIGKILL)
            except ProcessLookupError:
                pass
        self._win = None
        self._origin = None
        self._pid = None
        if self._x is not None:
            try:
                self._x.close()
            except Exception:
                pass
            self._x = None
        if wait_port:
            self._wait_port_free()

    @staticmethod
    def _port_holders():
        """Sockets on 1234 in any state, as (state, pid-or-None) - a lingering one makes the next
        simulator fail to bind and hang with an empty window, which is why stop() waits for them."""
        out = subprocess.run(["ss", "-tanp"], capture_output=True, text=True).stdout
        found = []
        for ln in out.splitlines()[1:]:
            if ":1234" not in ln:
                continue
            m = re.search(r"pid=(\d+)", ln)
            found.append((ln.split()[0], int(m.group(1)) if m else None))
        return found

    def _wait_port_free(self, timeout=30):
        """Wait for port 1234 to be free.  Whatever still holds it halfway through is killed: that is a
        monkeydo left behind by an interrupted run, or a simulator of an earlier session - and only
        one simulator can exist anyway."""
        end = time.time() + timeout
        killed = False
        while time.time() < end:
            holders = self._port_holders()
            if not holders:
                time.sleep(1.0)
                return True
            if not killed and time.time() > end - timeout / 2:
                for _, pid in holders:
                    if pid and pid != os.getpid():
                        log(f"killing pid {pid}, which still holds port 1234")
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                killed = True
            time.sleep(0.5)
        log("warning: port 1234 still busy after stop()")
        return False

    # ------------------------------------------------------------------ app
    def _stop_monkeydo(self):
        if self.monkeydo and self.monkeydo.poll() is None:
            try:
                os.killpg(self.monkeydo.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
            try:
                self.monkeydo.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.monkeydo.pid, signal.SIGKILL)
        self.monkeydo = None
        # leftovers from other runs (matched on the Java class, which no shell that calls this carries)
        out = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True, text=True).stdout
        for line in out.splitlines()[1:]:
            pid, _, args = line.strip().partition(" ")
            if "garmin.monkeybrains.monkeydodeux" in args and pid.isdigit() and int(pid) != os.getpid():
                try:
                    os.kill(int(pid), signal.SIGINT)
                except ProcessLookupError:
                    pass

    def app_files(self):
        return {"prg": os.path.join(APPS, "MEDIA", APP_NAME + ".PRG"),
                "set": os.path.join(APPS, "SETTINGS", APP_NAME + ".SET"),
                "dat": os.path.join(APPS, "DATA", APP_NAME + ".DAT"),
                "idx": os.path.join(APPS, "DATA", APP_NAME + ".IDX")}

    def push(self, prg, fresh_settings=True, fresh_storage=True, timeout=60, retry=True):
        """Push a .prg into the running simulator (always as APP.prg).  Kills a running app first.  With
        fresh_settings the variant's property defaults apply (stored settings removed); with fresh_storage
        the app's Application.Storage is removed too."""
        if not os.path.exists(prg):
            raise FileNotFoundError(prg)
        if self.monkeydo or os.path.exists(self.app_files()["prg"]):
            self.kill_app()
            time.sleep(1.0)
        f = self.app_files()
        if fresh_settings and os.path.exists(f["set"]):
            os.remove(f["set"])
        if fresh_storage:
            for k in ("dat", "idx"):
                if os.path.exists(f[k]):
                    os.remove(f[k])
        if os.path.exists(f["prg"]):
            os.remove(f["prg"])
        target = os.path.join(self.log_dir, APP_NAME + ".prg")
        shutil.copy(prg, target)
        self.pushed = prg
        self.applog_path = os.path.join(self.log_dir, "app-%02d.log" % (len([n for n in os.listdir(self.log_dir) if n.startswith("app-")]) + 1))
        out = open(self.applog_path, "wb")
        self.monkeydo = subprocess.Popen([os.path.join(SDK, "bin", "monkeydo"), target, self.device], stdout=out, stderr=out,
                                         stdin=subprocess.DEVNULL, start_new_session=True, cwd=self.log_dir)
        end = time.time() + timeout
        while time.time() < end:
            if os.path.exists(f["prg"]):
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("monkeydo did not upload the app (is the simulator running the right device?)")
        time.sleep(4.0)
        # The window title names the device the simulator is showing.  Switching devices can lag
        # behind the upload, and a simulator that came up in a bad state may not switch at all, so
        # wait for it and restart the simulator once if it never happens.
        end = time.time() + 15
        title = self.window_title() or ""
        while time.time() < end and " - " in title and not self._title_matches(title):
            time.sleep(1.0)
            title = self.window_title() or ""
        if " - " in title and not self._title_matches(title):
            if retry:
                log(f"simulator is showing {title!r}, not {self.device}; restarting it and pushing again")
                self.start(wipe=False)
                return self.push(prg, fresh_settings=fresh_settings, fresh_storage=fresh_storage,
                                 timeout=timeout, retry=False)
            raise RuntimeError(f"simulator is showing {title!r}, not {self.device}")
        log(f"pushed {os.path.basename(prg)} as {title!r} (log {self.applog_path})")
        return self

    def _title_matches(self, title):
        """Does the window title belong to this device?  Compared against the device's part-number names."""
        title = (title or "").lower()
        names = set()
        for key in ("displayName", "deviceName"):
            v = self.dev.sim.get(key) or self.dev.compiler.get(key)
            if v:
                names.add(str(v))
        for pn in self.dev.compiler.get("partNumbers", []):
            for k in ("displayName", "deviceName"):
                if pn.get(k):
                    names.add(str(pn[k]))
        if not names:
            return True
        for n in names:
            word = re.sub(r"[^a-z0-9]", "", n.split("/")[0].lower())
            if word and word in re.sub(r"[^a-z0-9]", "", title):
                return True
        return False

    def running(self, mark=0):
        """Is the widget itself on screen (rather than its glance / widget-loop page)?

        Debug builds announce themselves in the app log, but release builds print nothing, so the
        simulator's status bar decides: it shows the memory budget of whatever runs, and the glance
        page's budget is much smaller than the widget's."""
        if self.log_since(mark).strip():
            return True
        used, total = self.memory()
        if total is None:
            return False
        if not self.dev.glance_kb:
            return used is not None and used > 0     # no glance on this device: the loop page is the app
        return total > self.dev.glance_kb * 1.05

    def launch(self, timeout=15):
        """Open the widget from the glance list / widget loop: Down then Enter on the hotspots (as on the
        watch), falling back to a tap on the glance or Enter alone.  monkeydo often starts the app by
        itself, so an already-running app counts as launched.  Returns True once the app is on screen."""
        mark = self.log_mark()
        if self.running(mark):
            log("launched (app was already running after the push)")
            return True
        attempts = []
        if self.dev.has_key("down") and self.dev.has_key("enter"):
            attempts.append(("down+enter", lambda: (self.key("down"), self.key("enter"))))
        if self.dev.touch:
            w, h = self.display_size()
            attempts.append(("tap glance", lambda: self.tap(w // 2, h // 5)))
        if self.dev.has_key("enter"):
            attempts.append(("enter", lambda: self.key("enter")))
        if self.dev.has_key("start"):
            attempts.append(("start", lambda: self.key("start")))
        if self.dev.touch:
            w, h = self.display_size()
            attempts.append(("tap centre", lambda: self.tap(w // 2, h // 2)))
        for name, fn in attempts:
            fn()
            end = time.time() + 6
            while time.time() < end:
                if self.running(mark):
                    log(f"launched via {name}")
                    time.sleep(1.0)
                    return True
                time.sleep(1.0)
        log("launch: the app did not come up")
        return False

    def run(self, prg, **kw):
        self.push(prg, **kw)
        ok = self.launch()
        if not ok:
            self.shot("launch-failed", full=True)
        return ok

    # ------------------------------------------------------------------ logs
    def applog(self):
        try:
            return open(self.applog_path, "rb").read().decode(errors="replace")
        except FileNotFoundError:
            return ""

    def log_mark(self):
        return len(self.applog())

    def log_since(self, mark):
        return self.applog()[mark:]

    def wait_log(self, pattern, timeout=15, since=0):
        """Wait for a regex in the app output (System.println / debugLog); returns the match or None."""
        end = time.time() + timeout
        while time.time() < end:
            m = re.search(pattern, self.log_since(since))
            if m:
                return m
            time.sleep(0.3)
        return None

    def requests_in_log(self, since=0):
        return re.findall(r"^(GET|POST|REQUEST): (\S+?),", self.log_since(since), re.M)

    def crashed(self, since=0):
        return re.search(r"Encountered an app crash|Unhandled Exception|Error: ", self.log_since(since))

    @staticmethod
    def crash_mark():
        try:
            return os.path.getsize(CRASH_LOG)
        except FileNotFoundError:
            return 0

    @staticmethod
    def crashes_since(mark):
        try:
            with open(CRASH_LOG, "rb") as f:
                f.seek(mark)
                return f.read().decode(errors="replace")
        except FileNotFoundError:
            return ""

    def note(self, text):
        self.notes.append(text)
        log("NOTE " + text)


LOWMEM = {"instinct2x", "instinct2", "instinct2s", "instinctcrossover", "vivoactive3", "vivoactive3m", "venusq",
          "fenix5", "fenix5s", "fenix6", "fenix6s", "fenixchronos", "fr245", "fr55", "fr645", "fr935", "descentg1",
          "enduro"}


class Report:
    """Collects steps, checks and screenshots of a scenario into results/<name>/REPORT.md."""

    def __init__(self, name, sim=None):
        self.name = name
        self.sim = sim
        self.dir = sim.log_dir if sim else os.path.join(S, "results", name)
        os.makedirs(self.dir, exist_ok=True)
        self.lines = [f"# {name}", ""]
        self.failures = 0
        self.checks = 0

    def step(self, text):
        self.lines.append(f"- {text}")
        log("STEP " + text)

    def check(self, ok, text, detail=""):
        self.checks += 1
        if not ok:
            self.failures += 1
        mark = "PASS" if ok else "FAIL"
        self.lines.append(f"- **{mark}** {text}" + (f" — {detail}" if detail else ""))
        log(f"{mark} {text} {detail}")
        return ok

    def shot(self, label):
        path, _ = self.sim.shot(label)
        self.lines.append(f"  - ![{label}]({os.path.basename(path)})")
        return path

    def finish(self, verdict=None):
        verdict = verdict or ("PASS" if self.failures == 0 else f"FAIL ({self.failures} of {self.checks} checks)")
        self.lines.insert(2, f"**Result: {verdict}**")
        self.lines.append("")
        path = os.path.join(self.dir, "REPORT.md")
        open(path, "w").write("\n".join(self.lines) + "\n")
        log(f"report {path}: {verdict}")
        return path


# ---------------------------------------------------------------------- CLI
def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", "-d", default=os.environ.get("CIQ_DEVICE", "fenix7x"))
    ap.add_argument("--dir", default=os.environ.get("CIQ_LOGDIR"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("start").add_argument("--https", action="store_true")
    sub.add_parser("stop")
    p = sub.add_parser("push"); p.add_argument("prg"); p.add_argument("--keep-settings", action="store_true"); p.add_argument("--keep-storage", action="store_true")
    sub.add_parser("launch")
    p = sub.add_parser("run"); p.add_argument("prg"); p.add_argument("--keep-settings", action="store_true"); p.add_argument("--keep-storage", action="store_true")
    p = sub.add_parser("key"); p.add_argument("name"); p.add_argument("--hold", type=int, default=120)
    p = sub.add_parser("tap"); p.add_argument("x", type=int); p.add_argument("y", type=int)
    p = sub.add_parser("swipe"); [p.add_argument(a, type=int) for a in ("x1", "y1", "x2", "y2")]
    p = sub.add_parser("shot"); p.add_argument("name", nargs="?", default="shot"); p.add_argument("--full", action="store_true")
    sub.add_parser("ocr")
    sub.add_parser("status")
    p = sub.add_parser("menu"); p.add_argument("path", nargs="+")
    p = sub.add_parser("phone"); p.add_argument("state", choices=["on", "off"])
    p = sub.add_parser("wifi"); p.add_argument("state")
    sub.add_parser("killapp")
    sub.add_parser("log")
    p = sub.add_parser("mock"); p.add_argument("op"); p.add_argument("args", nargs="*"); p.add_argument("--https", action="store_true")
    a = ap.parse_args(argv)
    sim = Sim(a.device, a.dir)
    if a.cmd == "start":
        sim.start(https_requirements=a.https)
    elif a.cmd == "stop":
        sim.stop()
    elif a.cmd in ("push", "run"):
        getattr(sim, a.cmd)(a.prg, fresh_settings=not a.keep_settings, fresh_storage=not a.keep_storage)
    elif a.cmd == "launch":
        print(sim.launch())
    elif a.cmd == "key":
        sim.key(a.name, hold_ms=a.hold)
    elif a.cmd == "tap":
        sim.tap(a.x, a.y)
    elif a.cmd == "swipe":
        sim.swipe(a.x1, a.y1, a.x2, a.y2)
    elif a.cmd == "shot":
        print(sim.shot(a.name, full=a.full)[0])
    elif a.cmd == "ocr":
        print(sim.ocr())
    elif a.cmd == "status":
        print(sim.status_text())
    elif a.cmd == "menu":
        sim.menu(*a.path)
    elif a.cmd == "phone":
        sim.set_phone(a.state == "on")
    elif a.cmd == "wifi":
        sim.set_wifi(a.state)
    elif a.cmd == "killapp":
        sim.kill_app()
    elif a.cmd == "log":
        print(sim.applog())
    elif a.cmd == "mock":
        m = Mock(MOCK_HTTPS if a.https else MOCK_HTTP)
        if a.op == "reset":
            print(m.reset())
        elif a.op == "log":
            for e in m.log():
                print(e["ts"], e["method"], e["path"], "auth" if e["auth"] else "NOAUTH", json.dumps(e["body"])[:100])
        elif a.op == "set":
            print(m.set(a.args[0], a.args[1]))
        elif a.op == "fail":
            print(m.fail(int(a.args[0]), int(a.args[1]) if len(a.args) > 1 else 1))
        elif a.op == "state":
            print(json.dumps(m.state(), indent=1)[:3000])


if __name__ == "__main__":
    main(sys.argv[1:])
