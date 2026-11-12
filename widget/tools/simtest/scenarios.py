#!/usr/bin/env python3
"""Automated simulator scenarios for the five features on branch claude/lock-pin-wifi-lte-timer-fix.

Each scenario gets a fresh push of its variant (so the variant's property defaults apply and no state
from an earlier scenario leaks), drives the widget through the simulator, and checks what the app put
on screen, what it sent to the mock Home Assistant, and what it wrote to its log.

Scenarios are grouped by device because switching devices means restarting the simulator.

    run.py                 # every scenario
    run.py fenix7x         # one device
    run.py f7_lock_pin_ok  # one scenario

Devices under test (the user's list, plus fr255 which is the only non-touch full-memory model and so
the only way to reach the PIN digit wheel):

    fenix7x      full memory, round, touch + up/down, Wi-Fi radio, CIQ 5.2  -> keypad with focus ring
    venusq2      full memory, rectangular, touch, no up/down, NO Wi-Fi      -> keypad without ring
    edge1040     full memory, Edge family (:directwifi)                     -> direct Wi-Fi, no prompt
    fr255        full memory, round, NO touch                               -> PIN digit wheel
    instinct2x   64 KB (:lowmem), semi-octagon, sub-screen, CIQ 3.4.3       -> timer fix only
    vivoactive3  64 KB (:lowmem), round, touch, single button, CIQ 3.1.6    -> oldest Connect IQ
"""
import datetime as _dt
import io
import os
import re
import subprocess
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ciqsim import Sim, Mock, Report, MOCK_HTTP, MOCK_HTTPS, S, VARIANTS, LOWMEM, log

OLD_PRG = os.path.join(S, "out", "v230-fenix7x-debug.prg")   # release 2.3.0, built by build-master.sh

# Entities of the mock, in group order - the widget shows them in this order, so `index` below is how
# many "down" presses reach an entity from the first one.
ENTITIES = ["lock.front_door", "cover.garage", "light.kitchen", "switch.tv", "scene.movie",
            "script.goodnight", "input_number.volume", "input_select.mode", "sensor.temperature",
            "binary_sensor.door", "button.restart", "automation.lights", "fan.bedroom", "valve.water",
            "input_boolean.guest"]

REGISTRY = []


def scenario(device, name, feature):
    def wrap(fn):
        REGISTRY.append({"device": device, "name": name, "feature": feature, "fn": fn})
        return fn
    return wrap


# ---------------------------------------------------------------------------- helpers
def no_app(img):
    """The simulator's "no app running" screen: a blue triangle in the middle of the display."""
    a = np.asarray(img.convert("RGB")).astype(int)
    h, w = a.shape[:2]
    centre = a[int(h * 0.4):int(h * 0.6), int(w * 0.4):int(w * 0.6)].reshape(-1, 3)
    return float(((centre[:, 2] > 150) & (centre[:, 0] < 80)).mean()) > 0.3


def snap(sim, rep, label):
    """A screenshot saved into the report, returned as an image for checks made afterwards."""
    path, img = sim.shot(label)
    rep.lines.append(f"  - ![{label}]({os.path.basename(path)})")
    return img


def select_entity(sim, index):
    """Move from the first entity to `index` and select it, whatever controls the device has."""
    for _ in range(index):
        sim.next_page()
    sim.select()
    time.sleep(1.5)


def services_called(mock, since=0.0):
    return [(e["method"], e["path"], e["body"]) for e in mock.requests(since)
            if "/api/services/" in e["path"]]


def no_service_call(rep, mock, since, what):
    calls = services_called(mock, since)
    return rep.check(not calls, f"nothing was sent to Home Assistant {what}", f"calls: {calls}")


def fresh(sim, mock, variant, device=None, **kw):
    """Reset the mock and push a variant; returns the timestamp to measure requests from."""
    mock.reset()
    prg = f"{VARIANTS}/{variant}-{device or sim.device}.prg"
    since = time.time()
    sim.push(prg, **kw)
    launched = sim.launch()
    return since, launched


def wait_entities(sim, mock, timeout=25):
    """Wait for the startup import/refresh to finish (the last entity of the group arrived)."""
    return mock.wait_request(re.escape(ENTITIES[-1]), timeout=timeout) is not None


# ============================================================================ fenix7x
@scenario("fenix7x", "f7_loopback_http", "loopback http")
def f7_loopback_http(sim, rep):
    """Plain http to the loopback host is accepted and used (http://127.0.0.1:8123)."""
    m = sim.mock_http
    since, launched = fresh(sim, m, "base")
    rep.check(launched, "the widget opened")
    rep.check(wait_entities(sim, m), "all 15 entities were fetched over plain http",
              f"{len(m.requests(since))} requests")
    rep.shot("entity-list")
    ok, txt = sim.wait_text(r"front\s*door", timeout=8)
    rep.check(ok, "the first entity is shown", repr(txt))
    rep.check(not sim.crashed(), "no crash")


@scenario("fenix7x", "f7_http_uppercase", "loopback http")
def f7_http_uppercase(sim, rep):
    """http://LOCALHOST:8123 is accepted too - phone keyboards capitalise the first letter."""
    m = sim.mock_http
    since, launched = fresh(sim, m, "http-upper")
    rep.check(launched, "the widget opened")
    rep.check(wait_entities(sim, m), "the entities were fetched despite the upper-case host",
              f"{len(m.requests(since))} requests")
    rep.shot("entity-list")


@scenario("fenix7x", "f7_http_localhost", "loopback http")
def f7_http_localhost(sim, rep):
    """http://localhost:8123 - the name, not the address."""
    m = sim.mock_http
    since, launched = fresh(sim, m, "http-localhost")
    rep.check(launched, "the widget opened")
    rep.check(wait_entities(sim, m), "the entities were fetched from http://localhost",
              f"{len(m.requests(since))} requests")


@scenario("fenix7x", "f7_http_bad_host", "loopback http")
def f7_http_bad_host(sim, rep):
    """http://localhost.example.com is a different host on the internet and must stay rejected.

    The entities are imported over a good host first, so there is something to act on and the refusal
    can be seen on screen rather than merely inferred from silence."""
    m = sim.mock_http
    m.reset()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were imported with a working host first")

    # same stored entities, but now the widget is configured with the host under test
    since = time.time()
    sim.push(f"{VARIANTS}/http-bad-{sim.device}.prg", fresh_settings=True, fresh_storage=False)
    rep.check(sim.launch(), "the widget opened with the host that only looks like loopback")
    time.sleep(2)
    rep.shot("after-launch")
    sim.select()
    time.sleep(2.5)
    txt = sim.ocr()
    rep.shot("after-action")
    rep.check(re.search(r"invalid", txt, re.I) and re.search(r"settin", txt, re.I),
              "acting on an entity reports 'Check settings, invalid url'", repr(txt))
    rep.check(not m.requests(since), "nothing was sent to the host under test",
              f"{len(m.requests(since))} requests")


@scenario("fenix7x", "f7_http_userinfo", "loopback http")
def f7_http_userinfo(sim, rep):
    """http://localhost:8123@evil.example.com is user 'localhost' at evil.example.com - rejected.

    The entities are imported over a good host first, so there is something to act on and the refusal
    can be seen on screen rather than merely inferred from silence."""
    m = sim.mock_http
    m.reset()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were imported with a working host first")

    # same stored entities, but now the widget is configured with the host under test
    since = time.time()
    sim.push(f"{VARIANTS}/http-userinfo-{sim.device}.prg", fresh_settings=True, fresh_storage=False)
    rep.check(sim.launch(), "the widget opened with the host with user information")
    time.sleep(2)
    rep.shot("after-launch")
    sim.select()
    time.sleep(2.5)
    txt = sim.ocr()
    rep.shot("after-action")
    rep.check(re.search(r"invalid", txt, re.I) and re.search(r"settin", txt, re.I),
              "acting on an entity reports 'Check settings, invalid url'", repr(txt))
    rep.check(not m.requests(since), "nothing was sent to the host under test",
              f"{len(m.requests(since))} requests")


@scenario("fenix7x", "f7_lock_no_confirmation", "lock confirmation")
def f7_lock_no_confirmation(sim, rep):
    """With the setting off (the default) a lock still toggles straight away."""
    m = sim.mock_http
    since, _ = fresh(sim, m, "base")
    wait_entities(sim, m)
    mark = time.time()
    sim.key("enter")
    time.sleep(2)
    call = m.wait_request("lock/unlock", timeout=8, since=mark)
    rep.check(call is not None, "the lock was unlocked without any question")
    rep.shot("after-toggle")


def lock_question_up(sim):
    """Is the lock question on screen?  Its first line is the action, and the entity view never says
    "Unlock"."""
    return re.search(r"unlock", sim.ocr(), re.I) is not None


def lock_question(sim, rep, m):
    """Start from a locked door, select it and check that the question came up."""
    m.reset()
    m.set("lock.front_door", "locked")       # start from a known state, whatever ran before
    since, launched = fresh(sim, m, "lockyn")
    rep.check(launched, "the widget opened")
    wait_entities(sim, m)
    rep.check(m.state("lock.front_door") == "locked", "the door starts locked",
              m.state("lock.front_door"))
    sim.select()
    time.sleep(1.5)
    ok, txt = sim.wait_text(r"front\s*door", timeout=8)
    rep.check(ok and re.search(r"unlock", txt, re.I) is not None,
              "the question is 'Unlock Front Door?'", repr(txt))


def lock_unlocked(sim, rep, m, mark, how):
    call = m.wait_request("lock/unlock", timeout=10, since=mark, method="POST")
    rep.check(call is not None, f"{how} sends lock/unlock", f"calls: {services_called(m, mark)}")
    time.sleep(4)
    rep.check(m.state("lock.front_door") == "unlocked", "the door ends up unlocked",
              m.state("lock.front_door"))
    rep.shot("after-confirm")
    rep.check(not sim.crashed(), "no crash")


@scenario("fenix7x", "f7_lock_yesno", "lock confirmation")
def f7_lock_yesno(sim, rep):
    """Yes/no mode with the buttons: the question comes up with the focus on cancel, so the select
    button alone - the second press of an accidental double press - leaves the lock alone.  Back
    cancels as well; down, then select unlocks."""
    m = sim.mock_http
    lock_question(sim, rep, m)
    mark = time.time()
    rep.check(sim.lock_focus() == "cancel", "the focus starts on cancel", str(sim.lock_focus()))
    rep.shot("question")

    sim.key("enter")
    time.sleep(2.0)
    rep.check(not lock_question_up(sim), "select alone closes the question")
    no_service_call(rep, m, mark, "when select is pressed twice in a row")
    rep.check(m.state("lock.front_door") == "locked", "the door is still locked",
              m.state("lock.front_door"))
    rep.shot("after-select")

    sim.select()
    time.sleep(1.5)
    sim.back()
    time.sleep(2.0)
    rep.check(not lock_question_up(sim), "back closes the question")
    no_service_call(rep, m, mark, "when the question is left with back")

    mark = time.time()
    sim.select()
    time.sleep(1.5)
    sim.key("down")
    rep.check(sim.lock_focus() == "confirm", "down moves the focus to confirm", str(sim.lock_focus()))
    rep.shot("focus-on-confirm")
    sim.key("up")
    rep.check(sim.lock_focus() == "cancel", "up moves it back to cancel", str(sim.lock_focus()))
    sim.key("down")
    no_service_call(rep, m, mark, "while the focus is only moved")
    sim.key("enter")
    lock_unlocked(sim, rep, m, mark, "select on confirm")


@scenario("fenix7x", "f7_lock_yesno_touch", "lock confirmation")
def f7_lock_yesno_touch(sim, rep):
    """Yes/no mode by touch: a tap next to the keys is no answer, a tap on the cross cancels, and a
    double tap - the first opens the question, the second lands where the check mark is - does not
    confirm it.  A tap on the check mark a moment later does."""
    m = sim.mock_http
    lock_question(sim, rep, m)
    mark = time.time()
    cancel, confirm = sim.lock_key(False), sim.lock_key(True)
    w, h = sim.display_size()

    sim.tap(w // 2, confirm[1])
    time.sleep(1.0)
    rep.check(lock_question_up(sim), "a tap between the keys leaves the question up")
    sim.tap(*cancel)
    time.sleep(1.5)
    rep.check(not lock_question_up(sim), "a tap on the cross closes it")
    no_service_call(rep, m, mark, "after a tap between the keys and one on the cross")

    sim.tap(*confirm, hold_ms=40, settle=0.1)     # on the entity view: selects the lock
    sim.tap(*confirm, hold_ms=40, settle=0.1)     # on the question, a fifth of a second later
    time.sleep(1.5)
    rep.check(lock_question_up(sim), "after a double tap the question is up, unanswered")
    no_service_call(rep, m, mark, "when the second tap of a double tap lands on the check mark")
    rep.shot("after-double-tap")

    mark = time.time()
    sim.tap(*confirm)
    lock_unlocked(sim, rep, m, mark, "a tap on the check mark")


@scenario("fenix7x", "f7_lock_pin_ok", "lock confirmation")
def f7_lock_pin_ok(sim, rep):
    """PIN mode: the wallet-style screen appears and the right PIN unlocks."""
    m = sim.mock_http
    since, _ = fresh(sim, m, "lockpin")
    wait_entities(sim, m)

    mark = time.time()
    sim.key("enter")
    time.sleep(1.5)
    head = sim.header_text()
    rep.check(re.search(r"enter\s*pin", head, re.I) is not None,
              "the PIN screen appears", repr(head))
    rep.check(re.search(r"unlock.*front|front\s*door", head, re.I) is not None,
              "it says what the PIN is for", repr(head))
    rep.shot("pin-screen")
    rep.check(sim.pin_slots_filled() == 0, "all four slots start empty")

    sim.tap_digit(1)
    rep.check(sim.pin_slots_filled() == 1, "the first slot fills on the first digit")
    rep.shot("one-digit")
    no_service_call(rep, m, mark, "while the PIN is being entered")

    for d in (2, 3, 4):
        sim.tap_digit(d)
    call = m.wait_request("lock/unlock", timeout=10, since=mark)
    rep.check(call is not None, "the correct PIN unlocks the door without an extra confirm step")
    rep.shot("after-unlock")
    rep.check(not sim.crashed(), "no crash")


@scenario("fenix7x", "f7_lock_pin_wrong_and_lockout", "lock confirmation")
def f7_lock_pin_wrong_and_lockout(sim, rep):
    """A wrong PIN is refused and counted; three wrong entries lock it until the PIN is changed."""
    m = sim.mock_http
    since, _ = fresh(sim, m, "lockpin")
    wait_entities(sim, m)

    mark = time.time()
    sim.key("enter")
    sim.wait_text(r"enter\s*pin", timeout=8)

    for attempt, expect in ((1, r"2\s*attempts?\s*left"), (2, r"1\s*attempt\s*left")):
        for d in (9, 9, 9, 9):
            sim.tap_digit(d)
        time.sleep(1.0)
        ok, txt = sim.wait_text(r"wrong\s*pin", timeout=6)
        rep.check(ok, f"attempt {attempt}: 'Wrong PIN' is shown", repr(txt))
        head = sim.header_text()
        rep.check(re.search(expect, head, re.I) is not None,
                  f"attempt {attempt}: it says how many attempts are left", repr(head))
        rep.shot(f"wrong-{attempt}")
        no_service_call(rep, m, mark, f"after wrong attempt {attempt}")

    for d in (9, 9, 9, 9):
        sim.tap_digit(d)
    time.sleep(1.5)
    ok, txt = sim.wait_text(r"pin\s*locked|different\s*pin", timeout=8)
    rep.check(ok, "the third wrong entry locks the PIN", repr(txt))
    rep.shot("locked-out")
    no_service_call(rep, m, mark, "after the third wrong attempt")

    # and it survives a restart of the widget, with the same PIN still configured
    sim.push(f"{VARIANTS}/lockpin-{sim.device}.prg", fresh_settings=True, fresh_storage=False)
    sim.launch()
    wait_entities(sim, m, timeout=20)
    mark2 = time.time()
    sim.key("enter")
    time.sleep(2)
    ok, txt = sim.wait_text(r"pin\s*locked|different\s*pin", timeout=8)
    rep.check(ok, "it is still locked after the widget is restarted", repr(txt))
    rep.shot("locked-after-restart")
    no_service_call(rep, m, mark2, "while locked out after a restart")


@scenario("fenix7x", "f7_lock_pin_delete_and_leave", "lock confirmation")
def f7_lock_pin_delete_and_leave(sim, rep):
    """Delete removes the last digit; back on an empty PIN leaves without sending anything."""
    m = sim.mock_http
    since, _ = fresh(sim, m, "lockpin")
    wait_entities(sim, m)

    mark = time.time()
    sim.key("enter")
    sim.wait_text(r"enter\s*pin", timeout=8)

    sim.tap_digit(1)
    sim.tap_digit(2)
    rep.check(sim.pin_slots_filled() == 2, "two digits are in")
    sim.tap_delete()
    rep.check(sim.pin_slots_filled() == 1, "the delete key removes the last digit")
    rep.shot("after-delete")
    sim.key("esc")
    rep.check(sim.pin_slots_filled() == 0, "back removes the remaining digit")
    sim.key("esc")
    time.sleep(1.5)
    ok, txt = sim.wait_text(r"front\s*door", timeout=8)
    rep.check(ok, "back on an empty PIN returns to the entity", repr(txt))
    rep.shot("back-at-entity")
    no_service_call(rep, m, mark, "when the PIN screen is left")


@scenario("fenix7x", "f7_lock_pin_not_set", "lock confirmation")
def f7_lock_pin_not_set(sim, rep):
    """PIN mode with a PIN that is not four digits fails closed."""
    m = sim.mock_http
    since, _ = fresh(sim, m, "lockpin-bad")
    wait_entities(sim, m)
    mark = time.time()
    sim.key("enter")
    time.sleep(2)
    ok, txt = sim.wait_text(r"pin\s*not\s*set|not\s*4\s*digits|app\s*settings", timeout=8)
    rep.check(ok, "it refuses with 'Lock PIN not set or not 4 digits'", repr(txt))
    rep.shot("pin-not-set")
    no_service_call(rep, m, mark, "when the PIN setting is unusable")


@scenario("fenix7x", "f7_connection_wait", "waiting for the phone")
def f7_connection_wait(sim, rep):
    """Without the phone the widget waits instead of failing, and refreshes once it is back."""
    m = sim.mock_http
    m.reset()
    sim.set_ble("Not Connected")
    since = time.time()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    sim.launch()
    time.sleep(3)
    ok, txt = sim.wait_text(r"waiting\s*for|connection", timeout=12)
    rep.check(ok, "'Waiting for connection' is shown instead of an error", repr(txt))
    rep.shot("waiting")
    rep.check(not m.requests(since), "nothing was sent while there was no phone")

    time.sleep(6)
    rep.check(sim.running(), "the widget is still open after 10 s (it did not exit)")

    sim.set_ble("Connected")
    got = m.wait_request(re.escape(ENTITIES[-1]), timeout=30, since=since)
    rep.check(got is not None, "once the phone is back the entities are fetched",
              f"{len(m.requests(since))} requests")
    time.sleep(2)
    rep.shot("after-reconnect")
    ok, txt = sim.wait_text(r"front\s*door", timeout=10)
    rep.check(ok, "the loader is gone and the entity is shown", repr(txt))


@scenario("fenix7x", "f7_wait_back_to_stored", "waiting for the phone")
def f7_wait_back_to_stored(sim, rep):
    """Back on "Waiting for connection" leaves the loader for the stored entities, and the wait goes on
    quietly (ConnectionWait's own description).  Imported with the phone, launched again without it
    (storage kept), one back: the widget must stay open on the stored entity.

    Found with f7_dt_offline_mode: on every build tried, including the main tree's, the widget closed
    instead - the loader is a native Ui.ProgressBar, so presumably the system pops it on back and
    ConnectionWait.dismiss() pops once more, taking the entity view along."""
    m = sim.mock_http
    m.reset()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were imported with the phone connected")
    time.sleep(3)                         # stored after the last response
    sim.set_ble("Not Connected")
    since = time.time()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg", fresh_settings=True, fresh_storage=False)
    sim.launch()
    ok, txt = sim.wait_text(r"wa\w*it|con+e\w*ion", timeout=12)
    rep.check(ok, "without the phone, 'Waiting for connection' is shown", repr(txt))
    rep.shot("waiting")
    sim.back()
    time.sleep(3)
    img = snap(sim, rep, "after-one-back")
    rep.check(not no_app(img), "one back leaves the widget open (it does not close)")
    txt = sim.ocr(img)
    rep.check(re.search(r"front\s*door", txt, re.I) is not None, "the stored entity is shown (Front Door)",
              repr(txt[:80]))
    rep.check(not m.requests(since), "nothing was sent without the phone")


@scenario("fenix7x", "f7_wifi_offer_and_cancel", "Wi-Fi/LTE")
def f7_wifi_offer_and_cancel(sim, rep):
    """With the phone away the action is offered over Wi-Fi/LTE, and cancelling sends nothing."""
    m = sim.mock_https
    m.reset()
    sim.set_ble("Connected")
    sim.set_wifi("Not Connected")
    since = time.time()
    sim.push(f"{VARIANTS}/wifi-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were fetched over https")

    sim.set_ble("Not Connected")
    time.sleep(1)
    mark = time.time()
    select_entity(sim, 2)          # light.kitchen
    ok, txt = sim.wait_text(r"turning\s*off|kitchen", timeout=10)
    rep.check(ok, "a question is asked instead of acting straight away", repr(txt))
    rep.shot("wifi-question")
    rep.check(re.search(r"wi-?\s*fi|lte", txt, re.I) is not None,
              "the question says the action will go over Wi-Fi/LTE", repr(txt))

    sim.confirm(False)
    time.sleep(2)
    no_service_call(rep, m, mark, "when the Wi-Fi/LTE question is cancelled")
    rep.shot("after-cancel")
    rep.check(not sim.crashed(), "no crash")


@scenario("fenix7x", "f7_lock_yesno_wifi", "lock confirmation")
def f7_lock_yesno_wifi(sim, rep):
    """Yes/no mode without the phone: the lock's own question comes first, the Wi-Fi/LTE question
    after it, and cancelling the second one sends nothing."""
    m = sim.mock_https
    m.reset()
    m.set("lock.front_door", "locked")
    sim.set_ble("Connected")
    sim.set_wifi("Not Connected")
    sim.push(f"{VARIANTS}/wifi-lockyn-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were fetched over https")

    sim.set_ble("Not Connected")
    time.sleep(1)
    mark = time.time()
    sim.select()
    time.sleep(1.5)
    txt = sim.ocr()
    rep.check(re.search(r"unlock", txt, re.I) is not None and re.search(r"wi-?\s*fi|lte", txt, re.I) is None,
              "the lock's own question comes first", repr(txt))
    rep.check(sim.lock_focus() == "cancel", "its focus starts on cancel", str(sim.lock_focus()))
    rep.shot("lock-question")

    sim.lock_answer(True)
    ok, txt = sim.wait_text(r"wi-?\s*fi|lte", timeout=10)
    rep.check(ok, "the Wi-Fi/LTE question follows", repr(txt))
    rep.shot("wifi-question")
    no_service_call(rep, m, mark, "while the Wi-Fi/LTE question is open")

    sim.confirm(False)
    time.sleep(2)
    no_service_call(rep, m, mark, "when the Wi-Fi/LTE question is cancelled")
    rep.check(m.state("lock.front_door") == "locked", "the door is still locked",
              m.state("lock.front_door"))
    rep.shot("after-cancel")
    rep.check(not sim.crashed(), "no crash")


@scenario("fenix7x", "f7_wifi_confirm_starts_sync", "Wi-Fi/LTE")
def f7_wifi_confirm_starts_sync(sim, rep):
    """Confirming the Wi-Fi/LTE question hands the action to a system sync, which sends it.

    The simulator provides no real Wi-Fi transport inside a sync, so the request comes back with an
    error code; what matters here is that the action is attempted from inside the sync and that the
    failure is handled rather than crashing the app."""
    m = sim.mock_https
    m.reset()
    sim.set_ble("Connected")      # Wi-Fi is left at "Not Connected" by Sim.start()
    sim.push(f"{VARIANTS}/wifi-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were fetched over https")

    sim.set_ble("Not Connected")
    time.sleep(1)
    select_entity(sim, 2)
    ok, txt = sim.wait_text(r"turning\s*off|kitchen", timeout=10)
    rep.check(ok, "the action is offered rather than carried out", repr(txt))

    mark = sim.log_mark()
    crash_mark = sim.crash_mark()
    sim.confirm(True)
    time.sleep(6)
    rep.shot("after-confirm")
    sent = sim.log_since(mark)
    rep.check(re.search(r"POST: .*services/light/turn_", sent) is not None,
              "the stored action is sent from inside the sync", repr(sent[-200:]))
    rep.check(re.search(r"onWebResponse code=", sent) is not None,
              "the response is handed back to the app", repr(sent[-160:]))
    crashes = sim.crashes_since(crash_mark)
    rep.check("Not Enough Arguments" not in crashes and "Not Enough Arguments" not in sim.applog(),
              "the sync response does not crash the app", crashes[:200])
    rep.check(not sim.crashed(), "no crash while running the sync")
    sim.note("inside a sync the system calls the response callback without the :context argument, so "
             "the request is issued without that option and the context is held in the client")


@scenario("fenix7x", "f7_timers_rapid_actions", "timers (#101)")
def f7_timers_rapid_actions(sim, rep):
    """Issue #101: many actions and screen changes in a row must not run the device out of timers."""
    m = sim.mock_http
    crash_mark = sim.crash_mark()
    since, _ = fresh(sim, m, "closeauto")
    wait_entities(sim, m)

    for round_ in range(5):
        sim.key("enter")            # toggle the lock (transitional for 3 s in the mock)
        time.sleep(0.4)
        sim.key("down")
        sim.key("enter")            # toggle the cover
        time.sleep(0.4)
        sim.key("up")
        if round_ % 2 == 0:
            sim.key("menu", hold_ms=1300)
            time.sleep(0.6)
            sim.key("esc")
    time.sleep(4)
    rep.shot("after-rapid-actions")
    crashes = sim.crashes_since(crash_mark)
    rep.check("Too Many Timers" not in crashes and "Too Many Timers" not in sim.applog(),
              "no 'Too Many Timers Error'", crashes[:200])
    rep.check(not sim.crashed(), "no crash of any kind", (sim.crashed() or "").__str__()[:120])
    rep.check(len(services_called(m, since)) > 0, "the actions did reach Home Assistant",
              f"{len(services_called(m, since))} service calls")


@scenario("fenix7x", "f7_stale_settings", "settings upgrade")
def f7_stale_settings(sim, rep):
    """The crash you hit: settings stored by an older build lack the new keys.

    A build of release 2.3.0 is pushed first so the simulator stores its settings, then the current
    build runs on top of them without clearing them."""
    m = sim.mock_http
    m.reset()
    if not os.path.exists(OLD_PRG):
        rep.check(False, "the build of release 2.3.0 is available (build-master.sh)", OLD_PRG)
        return
    sim.set_ble("Connected")
    sim.push(OLD_PRG)
    sim.launch()
    time.sleep(6)
    rep.shot("2.3.0-running")

    crash_mark = sim.crash_mark()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg", fresh_settings=False, fresh_storage=False)
    launched = sim.launch()
    rep.check(launched, "the current build starts on settings written by the old build")
    time.sleep(3)
    sim.key("enter")              # the lock - this is where LockConfirm reads lockConfirmation
    time.sleep(3)
    rep.shot("after-selecting-the-lock")
    crashes = sim.crashes_since(crash_mark)
    rep.check("InvalidKey" not in crashes and "Unhandled Exception" not in crashes,
              "no InvalidKeyException from the missing setting", crashes[:300])
    rep.check(not sim.crashed(), "no crash")


# ============================================================================ venusq2
@scenario("venusq2", "vq_lock_pin_keypad", "lock confirmation")
def vq_lock_pin_keypad(sim, rep):
    """A touch watch without up/down buttons: the keypad has no focus ring, taps do the work."""
    m = sim.mock_http
    since, launched = fresh(sim, m, "lockpin")
    rep.check(launched, "the widget opened")
    wait_entities(sim, m)
    mark = time.time()
    sim.select()
    time.sleep(1.5)
    head = sim.header_text()
    rep.check(re.search(r"enter\s*pin", head, re.I) is not None,
              "the PIN screen appears on the rectangular screen", repr(head))
    rep.shot("pin-screen")

    sim.key("enter")
    time.sleep(0.8)
    rep.check(sim.pin_slots_filled() == 0,
              "the select button enters nothing (there is no focus ring without up/down)")

    for d in (1, 2, 3, 4):
        sim.tap_digit(d)
    call = m.wait_request("lock/unlock", timeout=10, since=mark)
    rep.check(call is not None, "tapping the PIN unlocks the door")
    rep.shot("after-unlock")


@scenario("venusq2", "vq_lock_yesno", "lock confirmation")
def vq_lock_yesno(sim, rep):
    """Yes/no mode on a touch watch without up/down buttons: no key has the focus, the select button
    answers nothing, and the keys are tapped."""
    m = sim.mock_http
    lock_question(sim, rep, m)
    mark = time.time()
    rep.check(sim.lock_focus() is None, "neither key has the focus", str(sim.lock_focus()))
    rep.shot("question")

    sim.key("enter")
    time.sleep(1.5)
    rep.check(lock_question_up(sim), "the select button leaves the question up")
    no_service_call(rep, m, mark, "when the select button is pressed on the question")

    sim.lock_answer(False)
    time.sleep(1.0)
    rep.check(not lock_question_up(sim), "a tap on the cross closes the question")
    no_service_call(rep, m, mark, "when the question is cancelled")

    mark = time.time()
    sim.select()
    time.sleep(1.5)
    sim.lock_answer(True)
    lock_unlocked(sim, rep, m, mark, "a tap on the check mark")


@scenario("venusq2", "vq_wifi_without_radio", "Wi-Fi/LTE")
def vq_wifi_without_radio(sim, rep):
    """The Venu Sq 2 has no Wi-Fi radio (the simulator shows "WiFi (Not Supported)"), so the setting
    must do nothing rather than offering a sync that cannot happen.

    The widget reports the missing phone and closes a couple of seconds later, so the screen is
    sampled from the moment the entity is selected."""
    m = sim.mock_https
    m.reset()
    sim.set_ble("Connected")
    sim.push(f"{VARIANTS}/wifi-{sim.device}.prg")
    sim.launch()
    wait_entities(sim, m)
    sim.set_ble("Not Connected")
    time.sleep(1)

    mark = time.time()
    select_entity(sim, 2)
    seen = []
    for _ in range(6):
        seen.append(sim.ocr())
        time.sleep(0.7)
    joined = " | ".join(seen)
    rep.shot("after-select-without-phone")
    rep.check(re.search(r"wi-?\s*fi|lte", joined, re.I) is None,
              "no Wi-Fi/LTE question on a watch without the radio", repr(joined[:160]))
    rep.check(re.search(r"phone|connect", joined, re.I) is not None,
              "the missing phone is reported", repr(joined[:160]))
    no_service_call(rep, m, mark, "without a phone and without a radio")


# ============================================================================ edge1040
@scenario("edge1040", "e10_direct_wifi", "Wi-Fi/LTE")
def e10_direct_wifi(sim, rep):
    """Edge units keep Wi-Fi up outside a sync, so they talk to Home Assistant directly and are never
    asked the Wi-Fi/LTE question (the :directwifi build).

    The request itself cannot complete here: over Wi-Fi the device does its own TLS handshake and
    refuses the test server's self-signed certificate with code 0 - the same failure the README warns
    about for real servers.  What this checks is that the widget sends the request itself instead of
    offering a sync."""
    m = sim.mock_https
    m.reset()
    # Import over the phone first: once Wi-Fi is up the Edge sends everything itself, and the test
    # server's self-signed certificate does not survive the device's own TLS handshake.
    sim.set_ble("Connected")
    sim.push(f"{VARIANTS}/wifi-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were imported while the phone was connected")

    sim.set_wifi("Connected")
    sim.set_ble("Not Connected")
    time.sleep(1.5)
    mark = sim.log_mark()
    select_entity(sim, 2)          # light.kitchen
    time.sleep(3.0)
    txt = sim.ocr()
    rep.shot("after-select-on-wifi")
    rep.check(re.search(r"wi-?\s*fi/?\s*lte|via\s*wi", txt, re.I) is None,
              "no Wi-Fi/LTE question on an Edge", repr(txt))
    sent = sim.log_since(mark)
    rep.check(re.search(r"^(GET|POST|REQUEST):", sent, re.M) is not None,
              "the widget sent the request itself, over Wi-Fi, without a sync",
              repr(sent[-200:]))
    rep.check(re.search(r"code=0|Unknown error", sent) is not None,
              "the handshake with the self-signed test certificate fails, as expected over Wi-Fi",
              repr(sent[-120:]))


@scenario("edge1040", "e10_lock_pin_layout", "lock confirmation")
def e10_lock_pin_layout(sim, rep):
    """The keypad has to fit the Edge's tall screen, and the keys have to be where they are drawn."""
    m = sim.mock_http
    since, launched = fresh(sim, m, "lockpin")
    rep.check(launched, "the widget opened")
    wait_entities(sim, m)
    mark = time.time()
    sim.select()
    time.sleep(1.5)
    head = sim.header_text()
    rep.check(re.search(r"enter\s*pin", head, re.I) is not None,
              "the PIN screen appears", repr(head))
    rep.shot("pin-screen")
    left, top, cw, ch = sim.keypad_geometry()
    w, h = sim.display_size()
    rep.check(left >= 0 and left + 3 * cw <= w and top + 4 * ch <= h,
              "the whole keypad fits on the display",
              f"grid {left:.0f},{top:.0f} {3 * cw:.0f}x{4 * ch:.0f} on {w}x{h}")
    for d in (1, 2, 3, 4):
        sim.tap_digit(d)
    call = m.wait_request("lock/unlock", timeout=10, since=mark)
    rep.check(call is not None, "every tapped digit landed on the right key")
    rep.shot("after-unlock")


# ============================================================================ fr255
@scenario("fr255", "fr_lock_pin_wheel", "lock confirmation")
def fr_lock_pin_wheel(sim, rep):
    """A watch without a touchscreen gets the wallet's digit wheel: up/down roll it, select takes it."""
    m = sim.mock_http
    since, launched = fresh(sim, m, "lockpin")
    rep.check(launched, "the widget opened")
    wait_entities(sim, m)
    mark = time.time()
    sim.key("enter")
    time.sleep(1.5)
    ok, txt = sim.wait_text(r"enter\s*pin", timeout=8)
    rep.check(ok, "the PIN screen appears", repr(txt))
    rep.check(not sim.dev.touch, "this device has no touchscreen, so the wheel is used")
    rep.shot("pin-wheel")
    sim.enter_pin("1234")
    call = m.wait_request("lock/unlock", timeout=12, since=mark)
    rep.check(call is not None, "the PIN entered on the wheel unlocks the door")
    rep.shot("after-unlock")
    rep.check(not sim.crashed(), "no crash")


@scenario("fr255", "fr_lock_yesno", "lock confirmation")
def fr_lock_yesno(sim, rep):
    """Yes/no mode on a watch without a touchscreen: select alone cancels, down and select unlock."""
    m = sim.mock_http
    lock_question(sim, rep, m)
    mark = time.time()
    rep.check(sim.lock_focus() == "cancel", "the focus starts on cancel", str(sim.lock_focus()))
    rep.shot("question")

    sim.lock_answer(False)
    time.sleep(1.0)
    rep.check(not lock_question_up(sim), "select alone closes the question")
    no_service_call(rep, m, mark, "when select is pressed twice in a row")

    mark = time.time()
    sim.key("enter")
    time.sleep(1.5)
    sim.key("down")
    rep.check(sim.lock_focus() == "confirm", "down moves the focus to confirm", str(sim.lock_focus()))
    rep.shot("focus-on-confirm")
    sim.key("enter")
    lock_unlocked(sim, rep, m, mark, "select on confirm")


# ============================================================================ instinct2x (64 KB)
@scenario("instinct2x", "i2_https_entities", "low memory")
def i2_https_entities(sim, rep):
    """The 64 KB build still imports and shows the group over https."""
    m = sim.mock_https
    since, launched = fresh(sim, m, "base")
    rep.check(launched, "the widget opened")
    rep.check(wait_entities(sim, m), "all entities were fetched",
              f"{len(m.requests(since))} requests")
    rep.shot("entity-list")
    rep.check(not sim.crashed(), "no crash")


@scenario("instinct2x", "i2_http_rejected", "loopback http")
def i2_http_rejected(sim, rep):
    """The loopback exception is a full-memory feature: 64 KB builds stay https-only.

    The entities are imported over https first, so acting on one shows the refusal."""
    https, http = sim.mock_https, sim.mock_http
    https.reset()
    http.reset()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, https), "the entities were imported over https first")

    since = time.time()
    sim.push(f"{VARIANTS}/http-base-{sim.device}.prg", fresh_settings=True, fresh_storage=False)
    rep.check(sim.launch(), "the widget opened with a plain http host")
    time.sleep(2)
    sim.select()
    time.sleep(2.5)
    txt = sim.ocr()
    rep.shot("after-action")
    rep.check(re.search(r"invalid", txt, re.I) and re.search(r"settin", txt, re.I),
              "plain http is rejected on a 64 KB device", repr(txt))
    rep.check(not http.requests(since), "nothing was sent over plain http",
              f"{len(http.requests(since))} requests")


@scenario("instinct2x", "i2_timers_rapid_actions", "timers (#101)")
def i2_timers_rapid_actions(sim, rep):
    """Issue #101 on the memory-constrained tier, where the fix also applies."""
    m = sim.mock_https
    crash_mark = sim.crash_mark()
    since, _ = fresh(sim, m, "base")
    wait_entities(sim, m)
    for round_ in range(5):
        sim.key("enter")
        time.sleep(0.4)
        sim.key("down")
        sim.key("enter")
        time.sleep(0.4)
        sim.key("up")
    time.sleep(4)
    rep.shot("after-rapid-actions")
    crashes = sim.crashes_since(crash_mark)
    rep.check("Too Many Timers" not in crashes, "no 'Too Many Timers Error'", crashes[:200])
    rep.check(not sim.crashed(), "no crash")
    used, total = sim.memory()
    rep.check(used is not None and used < total, "memory stayed within the budget", f"{used}/{total} kB")


@scenario("instinct2x", "i2_phone_lost", "waiting for the phone")
def i2_phone_lost(sim, rep):
    """64 KB devices must behave exactly as before: no waiting loader, and the stored entities shown.

    Checked side by side with a build of release 2.3.0 in this same scenario, because the only change
    meant for this tier there is the timer fix."""
    m = sim.mock_https
    m.reset()
    sim.set_ble("Connected")
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were imported with the phone connected")
    sim.set_ble("Not Connected")

    seen = {}
    for tag, prg in (("2.3.0", "v230"), ("current", "base")):
        path = f"{VARIANTS}/{prg}-{sim.device}.prg"
        if not os.path.exists(path):
            rep.check(False, f"the {tag} build is available", path)
            return
        since = time.time()
        sim.push(path, fresh_settings=True, fresh_storage=False)
        sim.launch()
        time.sleep(8)
        txt = sim.ocr()
        used, total = sim.memory()
        seen[tag] = (txt, used, total, len(m.requests(since)))
        rep.shot(f"{tag}-without-phone")
        rep.check(re.search(r"waiting", txt, re.I) is None,
                  f"{tag}: no 'Waiting for connection' loader on this tier", repr(txt[:80]))
        rep.check(sim.running(), f"{tag}: the widget stays open")
        rep.check(seen[tag][3] == 0, f"{tag}: nothing was sent without the phone")

    rep.check(seen["2.3.0"][2] == seen["current"][2],
              "2.3.0 and the current build run under the same memory budget",
              f"2.3.0 {seen['2.3.0'][1]}/{seen['2.3.0'][2]} kB, current {seen['current'][1]}/{seen['current'][2]} kB")
    sim.note(f"memory without the phone: 2.3.0 {seen['2.3.0'][1]} kB, current {seen['current'][1]} kB "
             f"of {seen['current'][2]} kB")
    sim.set_ble("Connected")


# ============================================================================ vivoactive3 (64 KB)
@scenario("vivoactive3", "va3_entities_and_timers", "timers (#101)")
def va3_entities_and_timers(sim, rep):
    """The oldest Connect IQ in the test set (3.1.6), touch with a single button."""
    m = sim.mock_https
    crash_mark = sim.crash_mark()
    since, launched = fresh(sim, m, "base")
    rep.check(launched, "the widget opened")
    rep.check(wait_entities(sim, m), "the entities were fetched",
              f"{len(m.requests(since))} requests")
    rep.shot("entity-list")
    w, h = sim.display_size()
    for _ in range(5):
        sim.key("enter")
        time.sleep(0.5)
        sim.swipe(w // 2, int(h * 0.75), w // 2, int(h * 0.25))
    time.sleep(4)
    rep.shot("after-rapid-actions")
    crashes = sim.crashes_since(crash_mark)
    rep.check("Too Many Timers" not in crashes, "no 'Too Many Timers Error'", crashes[:200])
    rep.check(not sim.crashed(), "no crash")


# ============================================================================ date and time
# The date/time entity types: time.*, date.*, datetime.* and input_datetime.*.  The contract the
# implementation follows, which the scenarios below check:
#  * Full-memory devices edit the value in a view of its own, opened by selecting the entity: a "+" band
#    at the top and a "-" band at the bottom (ZONE_FRACTION of the height, as InputNumberEditView), the
#    entity name at the top, then only the rows the entity has - YYYY-MM-DD and/or HH:MM.
#  * Fields year, month, day, hour, minute; the active one is a white box with black text, the first one
#    at the start.  Up +1, down -1, wrapping (the year clamps); select = next field, confirm on the last;
#    back = previous field, cancel on the first.  Touch: "+" band +1, "-" band -1, tapping a field makes
#    it active, tapping the active one = select.  The day clamps to the month's length.
#  * Sent, seconds always 00: time.set_value {"time": "HH:MM:00"}, date.set_value {"date": "YYYY-MM-DD"},
#    datetime.set_value {"datetime": "YYYY-MM-DDTHH:MM:00+HH:MM"} (the watch's local time and offset),
#    input_datetime.set_datetime with exactly {"date"}, {"time"} or {"datetime": "YYYY-MM-DD HH:MM:00"}.
#  * Shown afterwards as 2026-11-01, 14:30 or 2026-11-01 14:30, in local time.
#  * No phone and Wi-Fi/LTE execution on: confirming asks "Wi-Fi/LTE? / Setting <name> to <value>" first.
#  * 64 KB devices show the value read-only; selecting it does nothing.
#
# Builds: dt-<device>.prg and dtwifi-fenix7x.prg from build-dt-variants.sh (group=datetime).
# The mock's group.datetime, in group order - the index is how many next_page() reach an entity:
DT_ENTITIES = ["time.lunch", "date.deadline", "datetime.launch", "input_datetime.alarm",
               "input_datetime.vacation", "input_datetime.event"]
DT_LUNCH, DT_DEADLINE, DT_LAUNCH, DT_ALARM, DT_VACATION, DT_EVENT = range(len(DT_ENTITIES))
ZONE_FRACTION = 0.22          # InputNumberEditView.ZONE_FRACTION: the "+" and "-" bands
CRASH_RE = re.compile(r"Encountered an app crash|Unhandled Exception|^Error: [^\n]*\n(?:Details|Stack):", re.M)
_DIGIT_MAP = str.maketrans({"O": "0", "o": "0", "l": "1", "I": "1", "|": "1"})
# Settings > Time Display, kept in simulator.ini as TimeSetting.  Without the key the simulator runs on
# the 12-hour clock (System.DeviceSettings.is24Hour false), which gives the editor an AM/PM field.
TIME_SETTING = {"12": "0", "24": "1"}


def ensure_clock(sim, hours):
    """Put the simulator on the 12- or 24-hour clock.  It reads the setting at start only, so a change
    means a restart (written while no simulator runs - it rewrites the ini on exit).  True if it did."""
    from ciqsim import INI
    want = TIME_SETTING[hours]
    current = None
    if os.path.exists(INI):
        for line in open(INI).read().splitlines():
            if line.startswith("TimeSetting="):
                current = line.split("=", 1)[1].strip()
    if current == want:
        return False
    sim.stop()
    sim._ini(TimeSetting=want)
    sim.start()
    sim.note(f"the simulator was restarted on the {hours}-hour clock (TimeSetting={want})")
    return True


def dt_fresh(sim, mock, variant="dt", clock="24"):
    """Reset the mock and push <variant>-<device>.prg; returns (since, launched) like fresh().  On the
    full-memory devices the simulator is put on the `clock` ("24" or "12") first; the 64 KB tier shows
    the state as it is, on either clock."""
    from ciqsim import LOWMEM
    prg = f"{VARIANTS}/{variant}-{sim.device}.prg"
    if not os.path.exists(prg):
        raise FileNotFoundError(f"{prg} is missing - build it with build-dt-variants.sh")
    if sim.device not in LOWMEM:
        ensure_clock(sim, clock)
    return fresh(sim, mock, variant)


def wait_dt_entities(sim, mock, timeout=25, settle=2.5):
    """Wait until the import of group.datetime fetched its last member, then give the widget a moment
    to finish with it (the loader goes, the card is redrawn) before any key is pressed."""
    got = mock.wait_request(re.escape("/api/states/" + DT_ENTITIES[-1]) + "$", timeout=timeout) is not None
    if got:
        time.sleep(settle)
    elif re.search(r"wa\w*it|con+e\w*ion", sim.ocr(), re.I):     # OCR: "Weaitinnt", "conection"
        sim.note("the widget is waiting for the phone: the simulator's phone was not connected at launch - "
                 "a harness problem (the Settings menu between scenarios), not the widget's")
    return got


def goto(sim, index):
    """From the first entity to the one at `index`; the card view shows one entity at a time."""
    for _ in range(index):
        sim.next_page()
    time.sleep(1.5)           # the page bar shown on every move is gone a second later


def _components(mask):
    """4-connected components of a boolean array: (labels, [bounding slices]), label i at index i-1."""
    try:
        from scipy import ndimage
        labels, _ = ndimage.label(mask)
        return labels, ndimage.find_objects(labels)
    except ImportError:
        pass
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    slices = []
    for y0, x0 in zip(*np.nonzero(mask)):
        if labels[y0, x0]:
            continue
        n = len(slices) + 1
        labels[y0, x0] = n
        stack, box = [(y0, x0)], [y0, y0, x0, x0]
        while stack:
            y, x = stack.pop()
            box = [min(box[0], y), max(box[1], y), min(box[2], x), max(box[3], x)]
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not labels[ny, nx]:
                    labels[ny, nx] = n
                    stack.append((ny, nx))
        slices.append((slice(box[0], box[1] + 1), slice(box[2], box[3] + 1)))
    return labels, slices


def _fill_holes(mask):
    """`mask` with every region it encloses filled in (4-connected background, as scipy's default)."""
    try:
        from scipy import ndimage
        return ndimage.binary_fill_holes(mask)
    except ImportError:
        pass
    bg = ~mask
    reach = np.zeros_like(mask)
    reach[0, :], reach[-1, :], reach[:, 0], reach[:, -1] = bg[0, :], bg[-1, :], bg[:, 0], bg[:, -1]
    while True:
        grown = reach.copy()
        grown[1:, :] |= reach[:-1, :]
        grown[:-1, :] |= reach[1:, :]
        grown[:, 1:] |= reach[:, :-1]
        grown[:, :-1] |= reach[:, 1:]
        grown &= bg
        if (grown == reach).all():
            return ~reach
        reach = grown


def _opening(mask, k):
    """Morphological opening with a k x k square (k odd): what is thinner than k goes, rectangles stay."""
    def run(a, axis, reduce):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (k // 2, k // 2)
        win = np.lib.stride_tricks.sliding_window_view(np.pad(a, pad, constant_values=False), k, axis=axis)
        return reduce(win, axis=-1)
    eroded = run(run(mask, 0, np.all), 1, np.all)
    return run(run(eroded, 0, np.any), 1, np.any)


def editor_boxes(sim, img=None):
    """The active field between the editor's bands: a white filled box with dark text in it.

    The white parts of the screen are taken with the dark text inside them filled in, which makes the
    box one solid rectangle; an opening then removes everything thinner than about 4.5 % of the height -
    glyph strokes, and the "-" or ":" separators that touch the box when its padding reaches them.  What
    remains has to be box-shaped (at least about as wide as tall, solid) and must hold dark text (a
    glyph's filled-in counter is solid dark instead).  Returns dicts (cx, cy, w, h, bbox) in display
    coordinates, largest first."""
    img = img if img is not None else sim.display_shot()
    w, h = sim.display_size()
    top, bottom = int(h * ZONE_FRACTION) + 1, int(h * (1 - ZONE_FRACTION)) - 1
    mask = np.asarray(img.convert("L"))[top:bottom, :] > 200
    k = max(5, int(h * 0.045)) | 1
    filled = _fill_holes(mask)
    solid = _opening(filled, k)
    labels, slices = _components(solid)
    boxes = []
    for i, sl in enumerate(slices, 1):
        if sl is None:
            continue
        ys, xs = sl
        bh, bw = ys.stop - ys.start, xs.stop - xs.start
        if bw < 0.06 * w or bh < 0.04 * h or bw < 0.9 * bh:
            continue
        if (labels[sl] == i).mean() < 0.85:
            continue
        dark = 1.0 - float(mask[sl].mean())
        if not 0.05 <= dark <= 0.6:
            continue
        boxes.append({"cx": xs.start + bw / 2.0, "cy": top + ys.start + bh / 2.0, "w": bw, "h": bh,
                      "bbox": (xs.start, top + ys.start, xs.stop, top + ys.stop), "area": bw * bh,
                      "shape": filled[sl]})
    boxes.sort(key=lambda b: -b["area"])
    return boxes


def active_box(sim, img=None):
    boxes = editor_boxes(sim, img)
    return boxes[0] if boxes else None


def box_str(b):
    return "no white box found" if not b else f"box at ({b['cx']:.0f},{b['cy']:.0f}) {b['w']}x{b['h']}"


def editor_open(sim, img=None):
    """Are the editor's "+"/"-" bands on screen?  Four samples in the two bands, to the sides of the
    glyphs (and of a name, should it be drawn there) and inside a round screen, have to show one and the
    same colour, neither black nor white."""
    img = img if img is not None else sim.display_shot()
    w, h = sim.display_size()
    a = np.asarray(img.convert("RGB")).astype(int)
    pts = []
    for fx in (0.25, 0.75):
        for fy in (0.15, 0.85):
            x, y = int(w * fx), int(h * fy)
            pts.append(a[y - 2:y + 3, x - 2:x + 3].reshape(-1, 3).mean(axis=0))
    return bool(all(12 < p.mean() < 200 for p in pts) and all(np.abs(p - pts[0]).max() < 30 for p in pts))


def normalized(sim, img=None):
    """The display with the active field's box inverted: all text is then light on dark, and the OCR
    reads the active field too (it skips dark text in a white box on an otherwise dark screen)."""
    img = img if img is not None else sim.display_shot()
    a = np.asarray(img.convert("L")).copy()
    for b in editor_boxes(sim, img):
        x0, y0, x1, y1 = b["bbox"]
        # Only inside the box's own shape: its rounded corners are dark, and inverted they turn into
        # white wedges that the OCR reads as brackets ("[2" for a boxed "12" on the Venu Sq 2).
        region = a[y0:y1, x0:x1]
        a[y0:y1, x0:x1] = np.where(b["shape"], 255 - region, region)
    return Image.fromarray(a)


def editor_text(sim, img=None):
    """OCR of the editor: the whole display, and larger the strip under the "+" band with the name."""
    img = img if img is not None else sim.display_shot()
    w, h = sim.display_size()
    norm = normalized(sim, img)
    return (sim.ocr(norm, scale=4, psm=6) + "\n" +
            sim.ocr(norm.crop((0, int(h * ZONE_FRACTION), w, int(h * 0.45))), scale=6, psm=6))


def card_text(sim, img=None):
    """OCR of the entity card: the whole display, and larger its lower part with name and value."""
    img = img if img is not None else sim.display_shot()
    w, h = sim.display_size()
    return (sim.ocr(img, scale=4, psm=6) + "\n" +
            sim.ocr(img.crop((0, int(h * 0.42), w, int(h * 0.92))), scale=5, psm=6))


def _has(txt, part):
    """`part` in the OCR text; digits are matched with O/o read as 0 and l/I/| as 1, spaces ignored -
    so "14" and "05" are found in "14:05", "l4:O5" or "14 : 05"."""
    if part.isdigit():
        return part in re.sub(r"[ \t]+", "", txt.translate(_DIGIT_MAP))
    return part.lower() in txt.lower()


def time_row_digits(sim, img):
    """The editor's time row read on its own: the row of the active field, at twice the size, digits and
    ':' only.  The whole-screen OCR reads this font's "55" as "59" (fenix 7X, FONT_NUMBER_MEDIUM); this
    way every minute seen so far reads right (checked on 10 screenshots of known values)."""
    w, h = sim.display_size()
    b = active_box(sim, img)
    y0, y1 = (b["bbox"][1] - 4, b["bbox"][3] + 4) if b else (int(h * 0.4), int(h * 0.6))
    g = 255 - np.asarray(normalized(sim, img).crop((0, max(y0, 0), w, min(y1, h))).convert("L"))
    big = Image.fromarray(g).resize((g.shape[1] * 2, g.shape[0] * 2), Image.LANCZOS)
    bw = Image.fromarray(np.where(np.asarray(big) > 128, 255, 0).astype(np.uint8))
    padded = Image.new("L", (bw.size[0] + 40, bw.size[1] + 40), 255)
    padded.paste(bw, (20, 20))
    buf = io.BytesIO()
    padded.save(buf, format="PNG")
    out = subprocess.run(["tesseract", "stdin", "stdout", "--psm", "7", "-c", "tessedit_char_whitelist=0123456789:"],
                         input=buf.getvalue(), capture_output=True, timeout=60)
    return out.stdout.decode(errors="replace").strip()


def _minute_of(txt):
    """The minute of the first HH:MM (or H:MM) in OCR text, as a number, or None."""
    m = re.search(r"(\d{1,2})\s*:\s*(\d{2})", re.sub(r"[ \t]+", "", txt.translate(_DIGIT_MAP)))
    return int(m.group(2)) if m else None


def _matches(txt, parts, absent):
    return all(_has(txt, p) for p in parts) and not any(_has(txt, a) for a in absent)


def wait_editor(sim, parts, timeout=6.0, absent=()):
    """Poll the editor until its text holds every string of `parts` and none of `absent`."""
    end = time.time() + timeout
    while True:
        txt = editor_text(sim)
        if _matches(txt, parts, absent) or time.time() >= end:
            return _matches(txt, parts, absent), txt
        time.sleep(0.4)


def wait_card(sim, parts, timeout=8.0, absent=()):
    """Poll until the entity card - not the editor - shows every string of `parts` and none of `absent`."""
    end = time.time() + timeout
    while True:
        img = sim.display_shot()
        if editor_open(sim, img):
            ok, txt = False, "[the editor is still open] " + editor_text(sim, img)
        else:
            txt = card_text(sim, img)
            ok = _matches(txt, parts, absent)
        if ok or time.time() >= end:
            return ok, txt
        time.sleep(0.4)


def row_extent(sim, cy, half, img=None):
    """Left and right end of what is drawn in the editor row around y=cy (display coordinates)."""
    img = img if img is not None else sim.display_shot()
    w, h = sim.display_size()
    g = np.asarray(img.convert("L"))
    y0 = max(int(cy - half), int(h * ZONE_FRACTION) + 1)
    y1 = min(int(cy + half) + 1, int(h * (1 - ZONE_FRACTION)) - 1)
    x0, x1 = int(w * 0.06), int(w * 0.94)          # clear of the bezel in a round display's corners
    cols = np.nonzero((g[y0:y1, x0:x1] > 128).any(axis=0))[0]
    return None if len(cols) == 0 else (x0 + int(cols[0]), x0 + int(cols[-1]))


def field_point(sim, frac, cy, half, img=None):
    """Where a field sits in its row, as a fraction of the row's drawn width: "HH:MM" has the hour at
    0.2 and the minute at 0.8, "YYYY-MM-DD" the year at 0.2, the month at 0.6 and the day at 0.9."""
    ext = row_extent(sim, cy, half, img)
    if ext is None:
        return None
    return (int(ext[0] + frac * (ext[1] - ext[0])), int(cy))


def tap_box(sim, box, fallback):
    """Tap the centre of the active field's box, or `fallback` (display coordinates) without one."""
    x, y = (box["cx"], box["cy"]) if box else fallback
    sim.tap(int(x), int(y))


def check_body(rep, call, expected, what):
    """The service call carried exactly `expected` (entity_id and the service data, nothing more)."""
    body = call.get("body") if call else None
    status = call.get("status") if call else None
    return rep.check(body == expected, what, f"sent {body!r} -> HTTP {status}")


def check_no_crash(rep, sim, crash_mark):
    """No crash in the app's output (a crash prints "Error: <name>" with Details/Stack, then "Encountered
    an app crash") nor in the simulator's CIQ_LOG.YML.  Not sim.crashed(): that also matches the widget's
    own "Error: Phone not connected" and "RequestError: ..." lines."""
    m = CRASH_RE.search(sim.applog())
    logged = sim.crashes_since(crash_mark).strip()
    detail = (m.group(0)[:120] if m else "") + (f" | CIQ_LOG.YML: {logged[:200]!r}" if logged else "")
    return rep.check(m is None and not logged, "no crash", detail)


def open_editor(sim, rep, parts, what):
    """Select the entity on screen and wait for its editor; False (with a screenshot) when it did not
    open - the remaining steps would then act on the entity list instead."""
    sim.select()
    time.sleep(1.5)
    ok, txt = wait_editor(sim, parts)
    is_open = editor_open(sim)
    rep.check(ok, what, repr(txt))
    rep.check(is_open, "the editor draws its +/- bands")
    if not (ok or is_open):
        rep.shot("no-editor")
        return False
    return True


def launch_expectations():
    """datetime.launch is 2026-11-01T13:30:00+00:00.  The simulator's clock follows the host's time zone,
    so the expected local value and offset come from the host's zone at that date (not the offset of
    today - though for this date both are the same until the next DST change)."""
    utc = _dt.datetime(2026, 11, 1, 13, 30, tzinfo=_dt.timezone.utc)
    wall = utc.astimezone().replace(tzinfo=None)            # local wall time on the watch
    new = wall.replace(minute=(wall.minute + 1) % 60)      # one up on the minute: it wraps, nothing carries
    sent = new.astimezone()                                 # the host's offset at that wall time
    z = sent.strftime("%z")
    offset = z[:3] + ":" + z[3:]
    return {"wall": wall, "new": new, "offset": offset, "offset_s": int(utc.astimezone().utcoffset().total_seconds()),
            "body": f"{new:%Y-%m-%dT%H:%M}:00{offset}", "instant": sent.astimezone(_dt.timezone.utc),
            "utc_equals_local": utc.utcoffset() == utc.astimezone().utcoffset()}


# ---------------------------------------------------------------------------- shared flows
def _dt_time_buttons(sim, rep):
    """time.lunch with the buttons: up twice 12 -> 14, select, up five times 00 -> 05, select sends."""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(launched, "the widget opened")
    rep.check(wait_dt_entities(sim, m), "the six date/time entities were imported",
              f"{len(m.requests(since))} requests")
    ok, txt = wait_card(sim, ["12", "00"])
    rep.check(ok, "the card shows time.lunch as 12:00", repr(txt))
    rep.shot("card-before")

    mark = time.time()
    if not open_editor(sim, rep, ["12", "00"], "selecting time.lunch opens the editor at 12:00"):
        return
    txt = editor_text(sim)
    rep.check(re.search(r"lunch", txt, re.I) is not None, "the editor shows the name (Lunch)", repr(txt))
    w = sim.display_size()[0]
    hour = active_box(sim)
    rep.check(hour is not None and hour["cx"] < w / 2,
              "the hour is the active field (white box, left of centre)", box_str(hour))
    rep.shot("editor-open")

    # The hour wraps: 13 times down from 12 passes 00 and comes out at 23.  Back on the first field then
    # leaves without sending anything, and the main flow starts again from the stored 12:00.
    for _ in range(13):
        sim.key("down", settle=0.4)
    ok, txt = wait_editor(sim, ["23", "00"])
    rep.check(ok, "down 13 times from 12: the hour wraps from 00 to 23", repr(txt))
    rep.shot("editor-hour-wrapped")
    sim.back()
    time.sleep(1.0)
    rep.check(not editor_open(sim), "back on the hour (the first field) leaves the editor")
    no_service_call(rep, m, mark, "after the wrap and back")
    if not open_editor(sim, rep, ["12", "00"], "the editor opens again at the stored 12:00"):
        return

    for _ in range(2):
        sim.key("up", settle=0.5)
    ok, txt = wait_editor(sim, ["14", "00"])
    rep.check(ok, "up twice: 14:00", repr(txt))
    rep.shot("editor-14-00")

    sim.select()
    minute = active_box(sim)
    rep.check(minute is not None and hour is not None and minute["cx"] > hour["cx"] + 0.05 * w,
              "select moves to the minute (the box moves right)", f"{box_str(hour)} -> {box_str(minute)}")
    for _ in range(5):
        sim.key("up", settle=0.4)
    ok, txt = wait_editor(sim, ["14", "05"])
    rep.check(ok, "up five times: 14:05", repr(txt))
    no_service_call(rep, m, mark, "while the value is edited")
    rep.shot("editor-14-05")

    sim.select()
    call = m.wait_request(r"^/api/services/time/set_value$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "select on the minute (the last field) sends time/set_value",
              f"calls: {services_called(m, mark)}")
    check_body(rep, call, {"entity_id": "time.lunch", "time": "14:05:00"},
               'the body is exactly {"time": "14:05:00"} for time.lunch (seconds 00)')
    time.sleep(1.5)
    rep.check(m.state("time.lunch") == "14:05:00", "Home Assistant (the mock) now reports 14:05:00",
              m.state("time.lunch"))
    ok, txt = wait_card(sim, ["14", "05"], timeout=10)
    rep.check(ok, "back on the card, it shows 14:05", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


def _dt_time_touch(sim, rep):
    """time.lunch by touch: two taps on the "+" band 12 -> 14, a tap on the active hour moves on to the
    minute, five taps 00 -> 05, a tap on the active minute (the last field) sends."""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(launched, "the widget opened")
    rep.check(wait_dt_entities(sim, m), "the six date/time entities were imported",
              f"{len(m.requests(since))} requests")
    ok, txt = wait_card(sim, ["12", "00"])
    rep.check(ok, "the card shows time.lunch as 12:00", repr(txt))

    w, h = sim.display_size()
    plus = (w // 2, int(h * ZONE_FRACTION / 2))
    mark = time.time()
    if not open_editor(sim, rep, ["12", "00"], "selecting time.lunch opens the editor at 12:00"):
        return
    hour = active_box(sim)
    rep.check(hour is not None and hour["cx"] < w / 2,
              "the hour is the active field (white box, left of centre)", box_str(hour))
    rep.shot("editor-open")

    for _ in range(2):
        sim.tap(*plus, settle=0.5)
    ok, txt = wait_editor(sim, ["14", "00"])
    rep.check(ok, "two taps on the + band: 14:00", repr(txt))
    rep.shot("editor-14-00")

    # The hour box was found before the taps; the field does not move when its value changes.
    hour_now = active_box(sim) or hour
    cy = hour_now["cy"] if hour_now else h / 2
    tap_box(sim, hour_now, field_point(sim, 0.2, cy, h * 0.05) or (w / 2 - 0.12 * w, cy))
    minute = active_box(sim)
    rep.check(minute is not None and hour_now is not None and minute["cx"] > hour_now["cx"] + 0.05 * w,
              "a tap on the active hour moves to the minute", f"{box_str(hour_now)} -> {box_str(minute)}")
    no_service_call(rep, m, mark, "after tapping the active hour (not the last field)")

    for _ in range(5):
        sim.tap(*plus, settle=0.4)
    ok, txt = wait_editor(sim, ["14", "05"])
    rep.check(ok, "five taps on the + band: 14:05", repr(txt))
    rep.shot("editor-14-05")

    minute_now = active_box(sim) or minute
    tap_box(sim, minute_now, field_point(sim, 0.8, cy, h * 0.05) or (w / 2 + 0.12 * w, cy))
    call = m.wait_request(r"^/api/services/time/set_value$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "a tap on the active minute (the last field) sends time/set_value",
              f"calls: {services_called(m, mark)}")
    check_body(rep, call, {"entity_id": "time.lunch", "time": "14:05:00"},
               'the body is exactly {"time": "14:05:00"} for time.lunch')
    time.sleep(1.5)
    ok, txt = wait_card(sim, ["14", "05"], timeout=10)
    rep.check(ok, "back on the card, it shows 14:05", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


def _dt_readonly(sim, rep):
    """64 KB build: the group is imported over https and shown, but selecting a value does nothing."""
    m = sim.mock                  # the TLS mock: the 64 KB builds are https-only
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(launched, "the widget opened")
    rep.check(wait_dt_entities(sim, m, timeout=40), "group.datetime was imported over https",
              f"{len(m.requests(since))} requests")
    fetched = {e["path"].rsplit("/", 1)[-1] for e in m.requests(since) if e["method"] == "GET"}
    missing = [e for e in DT_ENTITIES if e not in fetched]
    rep.check(not missing, "all six members were fetched", f"missing: {missing}")

    def on_loop_page():
        return re.search(r"hass\s*control", sim.ocr(), re.I) is not None

    if on_loop_page():
        # The vivoactive 3 has no glances: the widget opens on its own page of the widget loop
        # (BaseView), and a tap enters the entity view - its single button does not.
        w, h = sim.display_size()
        sim.tap(w // 2, h // 2)
        time.sleep(2.5)
        rep.check(not on_loop_page(), "a tap on the widget's page in the loop opens the entity card")
    ok, txt = wait_card(sim, ["12", "00"], timeout=10)
    rep.check(ok, "the card shows time.lunch's value (12 and 00 anywhere - OCR is poor on this screen)",
              repr(txt))
    rep.shot("card")

    mark = time.time()
    if sim.dev.touch:
        w, h = sim.display_size()
        sim.tap(w // 2, h // 2)       # a tap on the card is what selects on a touch screen
    else:
        sim.select()
    time.sleep(3)
    rep.shot("after-select")
    reqs = m.requests(mark)
    rep.check(not reqs, "selecting it sends nothing (read-only on 64 KB devices)",
              f"{[(e['method'], e['path']) for e in reqs]}")
    check_no_crash(rep, sim, crash_mark)
    rep.check(sim.running(), "the widget is still running")
    used, total = sim.memory()
    rep.check(used is not None and total is not None and used < total,
              "the simulator reports memory within the budget", f"{used}/{total} kB")


# ============================================================================ fenix7x: date and time
@scenario("fenix7x", "f7_dt_time_buttons", "date and time")
def f7_dt_time_buttons(sim, rep):
    """time.lunch (12:00:00) on the buttons: the editor shows the name and 12:00 with the hour active;
    up twice gives 14:00, select moves to the minute, up five times gives 14:05, select on the last
    field sends time/set_value {"time": "14:05:00"} and the card then shows 14:05."""
    _dt_time_buttons(sim, rep)


@scenario("fenix7x", "f7_dt_date_clamps", "date and time")
def f7_dt_date_clamps(sim, rep):
    """date.deadline (2026-01-31): select leaves the year as it is and moves to the month; up makes it
    February and the day follows to 28; select, select sends date/set_value {"date": "2026-02-28"}."""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    goto(sim, DT_DEADLINE)
    ok, txt = wait_card(sim, ["2026", "01", "31"])
    rep.check(ok, "the card shows date.deadline as 2026-01-31", repr(txt))

    mark = time.time()
    if not open_editor(sim, rep, ["2026", "01", "31"], "the editor opens at 2026-01-31"):
        return
    year = active_box(sim)
    rep.check(year is not None, "the first field (the year) is active", box_str(year))
    rep.shot("editor-open")

    sim.select()
    month = active_box(sim)
    rep.check(year is not None and month is not None and month["cx"] > year["cx"],
              "select moves to the month (the box moves right)", f"{box_str(year)} -> {box_str(month)}")
    sim.key("up")
    ok, txt = wait_editor(sim, ["2026", "02", "28"])
    rep.check(ok, "up on the month: 2026-02-28 - February, and the day clamped from 31 to 28", repr(txt))
    rep.shot("editor-feb-28")

    sim.select()
    day = active_box(sim)
    rep.check(month is not None and day is not None and day["cx"] > month["cx"],
              "select moves to the day", f"{box_str(month)} -> {box_str(day)}")
    no_service_call(rep, m, mark, "before the last field is confirmed")
    sim.select()
    call = m.wait_request(r"^/api/services/date/set_value$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "select on the day (the last field) sends date/set_value",
              f"calls: {services_called(m, mark)}")
    check_body(rep, call, {"entity_id": "date.deadline", "date": "2026-02-28"},
               'the body is exactly {"date": "2026-02-28"}')
    time.sleep(1.5)
    rep.check(m.state("date.deadline") == "2026-02-28", "the mock now reports 2026-02-28",
              m.state("date.deadline"))
    ok, txt = wait_card(sim, ["2026", "02", "28"], timeout=10)
    rep.check(ok, "the card shows 2026-02-28", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_datetime_local", "date and time")
def f7_dt_datetime_local(sim, rep):
    """datetime.launch is stored in UTC (2026-11-01T13:30:00+00:00) and shown in the watch's local time.
    Four selects reach the minute, up adds one, select sends datetime/set_value with the local time and
    the watch's offset ("YYYY-MM-DDTHH:MM:00+HH:MM"); the card then shows the new local time.  The
    simulator follows the host's time zone, so the expectations are computed from it."""
    m = sim.mock
    crash_mark = sim.crash_mark()
    exp = launch_expectations()
    wall, new = exp["wall"], exp["new"]
    if exp["utc_equals_local"]:
        sim.note("the host runs on UTC, so local time and UTC look the same here - this scenario cannot "
                 "tell a missing conversion from a correct one")
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    goto(sim, DT_LAUNCH)
    ok, txt = wait_card(sim, [f"{wall:%Y}", f"{wall:%H}", f"{wall:%M}"])
    rep.check(ok, f"the card shows datetime.launch in local time ({wall:%Y-%m-%d %H:%M}, offset "
                  f"{exp['offset']})", repr(txt))
    rep.shot("card-before")
    logged = sim.wait_log(r"DateTimeValue: UTC offset (-?\d+) s", timeout=6)
    rep.check(logged is not None and int(logged.group(1)) == exp["offset_s"],
              f"the watch's UTC offset (app log) is the host zone's at that date, {exp['offset_s']} s - "
              f"the expectations here are computed from it", logged.group(0) if logged else "no such log line")

    mark = time.time()
    if not open_editor(sim, rep, [f"{wall:%Y}", f"{wall:%H}", f"{wall:%M}"],
                       f"the editor opens at the local {wall:%Y-%m-%d %H:%M}"):
        return
    w = sim.display_size()[0]
    year = active_box(sim)
    rep.check(year is not None, "the first field (the year) is active", box_str(year))
    rep.shot("editor-open")
    for _ in range(4):
        sim.select()
    minute = active_box(sim)
    rep.check(year is not None and minute is not None and minute["cy"] > year["cy"] + 5
              and minute["cx"] > w / 2,
              "four selects reach the minute (lower row, right part)", f"{box_str(year)} -> {box_str(minute)}")
    sim.key("up")
    ok, txt = wait_editor(sim, [f"{new:%H}", f"{new:%M}"])
    rep.check(ok, f"up on the minute: {new:%H:%M}", repr(txt))
    no_service_call(rep, m, mark, "before the last field is confirmed")
    rep.shot("editor-plus-one-minute")

    sim.select()
    call = m.wait_request(r"^/api/services/datetime/set_value$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "select on the minute (the last field) sends datetime/set_value",
              f"calls: {services_called(m, mark)}")
    check_body(rep, call, {"entity_id": "datetime.launch", "datetime": exp["body"]},
               f"the body is exactly {{\"datetime\": \"{exp['body']}\"}} - local time, the host's offset")
    sent = call["body"].get("datetime") if call and isinstance(call.get("body"), dict) else None
    try:
        instant = _dt.datetime.fromisoformat(sent).astimezone(_dt.timezone.utc) if sent else None
    except (TypeError, ValueError):
        instant = None
    rep.check(instant == exp["instant"], "it denotes the intended moment (13:31 UTC)", f"{sent} -> {instant}")
    time.sleep(1.5)
    rep.check(m.state("datetime.launch") == exp["body"], "the mock stored it as sent", m.state("datetime.launch"))
    ok, txt = wait_card(sim, [f"{new:%H}", f"{new:%M}"], timeout=10)
    rep.check(ok, f"the card shows the new local time {new:%H:%M}", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_input_datetime_time_only", "date and time")
def f7_dt_input_datetime_time_only(sim, rep):
    """input_datetime.alarm has a time only (has_date false): the editor has no date row; up makes 06:30
    07:30, select, select sends input_datetime/set_datetime with "time": "07:30:00" and no date or
    datetime key (the mock refuses those for a time-only entity with 400, as Home Assistant would)."""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    goto(sim, DT_ALARM)
    ok, txt = wait_card(sim, ["06", "30"])
    rep.check(ok, "the card shows input_datetime.alarm as 06:30", repr(txt))

    mark = time.time()
    if not open_editor(sim, rep, ["06", "30"], "the editor opens at 06:30"):
        return
    txt = editor_text(sim)
    rep.check(re.search(r"(19|20)\d\d", txt) is None, "only a time row: no year anywhere on the editor",
              repr(txt))
    rep.shot("editor-open")
    sim.key("up")
    ok, txt = wait_editor(sim, ["07", "30"])
    rep.check(ok, "up on the hour: 07:30", repr(txt))
    sim.select()
    no_service_call(rep, m, mark, "before the last field is confirmed")
    sim.select()
    call = m.wait_request(r"^/api/services/input_datetime/set_datetime$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "select on the minute sends input_datetime/set_datetime",
              f"calls: {services_called(m, mark)}")
    body = call.get("body") if call else None
    body = body if isinstance(body, dict) else {}
    rep.check(body.get("time") == "07:30:00" and body.get("entity_id") == "input_datetime.alarm",
              'it sets "time": "07:30:00" on input_datetime.alarm', f"sent {body!r}")
    rep.check("date" not in body and "datetime" not in body, "and has no date or datetime key",
              f"sent {body!r} -> HTTP {call.get('status') if call else None}")
    time.sleep(1.5)
    rep.check(m.state("input_datetime.alarm") == "07:30:00", "the mock accepted it: 07:30:00",
              m.state("input_datetime.alarm"))
    ok, txt = wait_card(sim, ["07", "30"], timeout=10)
    rep.check(ok, "the card shows 07:30", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_input_datetime_both", "date and time")
def f7_dt_input_datetime_both(sim, rep):
    """input_datetime.event (date and time, 2026-12-24 18:00:00): up on the month wraps 12 to 01 (the
    year stays), down on the minute wraps 00 to 59 (the hour stays); confirming sends
    input_datetime/set_datetime with exactly {"datetime": "2026-01-24 18:59:00"} - a space, no offset.
    (Beyond the requested list: covers down = -1, wrapping and the both-format body.)"""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    goto(sim, DT_EVENT)
    mark = time.time()
    if not open_editor(sim, rep, ["2026", "12", "24", "18", "00"], "the editor opens at 2026-12-24 18:00"):
        return
    rep.shot("editor-open")
    sim.select()                      # year -> month
    sim.key("up")
    ok, txt = wait_editor(sim, ["2026", "01", "24"], absent=["12"])
    rep.check(ok, "up on month 12 wraps to 01, the year stays 2026", repr(txt))
    rep.shot("editor-month-wrapped")
    for _ in range(3):                # month -> day -> hour -> minute
        sim.select()
    sim.key("down")
    ok, txt = wait_editor(sim, ["18", "59"])
    rep.check(ok, "down on minute 00 wraps to 59, the hour stays 18", repr(txt))
    rep.shot("editor-minute-wrapped")
    no_service_call(rep, m, mark, "before the last field is confirmed")
    sim.select()
    call = m.wait_request(r"^/api/services/input_datetime/set_datetime$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "select on the minute sends input_datetime/set_datetime",
              f"calls: {services_called(m, mark)}")
    body = call.get("body") if call else None
    rep.check(isinstance(body, dict) and set(body) == {"entity_id", "datetime"},
              "with a datetime key only (no separate date or time)", f"sent {body!r}")
    sent = body.get("datetime") if isinstance(body, dict) else None
    rep.check(isinstance(sent, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:00", sent) is not None,
              'in the form "YYYY-MM-DD HH:MM:00" (space, seconds 00, no offset)', repr(sent))
    check_body(rep, call, {"entity_id": "input_datetime.event", "datetime": "2026-01-24 18:59:00"},
               'the body is exactly {"datetime": "2026-01-24 18:59:00"}')
    time.sleep(1.5)
    rep.check(m.state("input_datetime.event") == "2026-01-24 18:59:00", "the mock now reports it",
              m.state("input_datetime.event"))
    ok, txt = wait_card(sim, ["2026", "01", "24", "18", "59"], timeout=10)
    rep.check(ok, "the card shows 2026-01-24 18:59", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_input_datetime_date_only", "date and time")
def f7_dt_input_datetime_date_only(sim, rep):
    """input_datetime.vacation has a date only (2026-07-01): no time row; down on the day wraps 01 to 31
    (July's length); confirming sends input_datetime/set_datetime {"date": "2026-07-31"} and nothing else.
    (Beyond the requested list: covers the date-only body and the day wrapping down.)"""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    goto(sim, DT_VACATION)
    mark = time.time()
    if not open_editor(sim, rep, ["2026", "07", "01"], "the editor opens at 2026-07-01"):
        return
    txt = editor_text(sim)
    rep.check(re.search(r"\d\d\s*:\s*\d\d", txt) is None, "only a date row: no HH:MM on the editor", repr(txt))
    rep.shot("editor-open")
    sim.select()                      # year -> month
    sim.select()                      # month -> day
    sim.key("down")
    ok, txt = wait_editor(sim, ["2026", "07", "31"])
    rep.check(ok, "down on day 01 wraps to 31 (July)", repr(txt))
    no_service_call(rep, m, mark, "before the last field is confirmed")
    sim.select()
    call = m.wait_request(r"^/api/services/input_datetime/set_datetime$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "select on the day (the last field) sends input_datetime/set_datetime",
              f"calls: {services_called(m, mark)}")
    check_body(rep, call, {"entity_id": "input_datetime.vacation", "date": "2026-07-31"},
               'the body is exactly {"date": "2026-07-31"} - no time or datetime key')
    time.sleep(1.5)
    rep.check(m.state("input_datetime.vacation") == "2026-07-31", "the mock accepted it: 2026-07-31",
              m.state("input_datetime.vacation"))
    ok, txt = wait_card(sim, ["2026", "07", "31"], timeout=10)
    rep.check(ok, "the card shows 2026-07-31", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_cancel", "date and time")
def f7_dt_cancel(sim, rep):
    """input_datetime.event: up makes the year 2027, select moves to the month, back returns to the year
    (still editing), back on the first field cancels - nothing is sent and the card still shows
    2026-12-24 18:00."""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    goto(sim, DT_EVENT)
    ok, txt = wait_card(sim, ["2026", "12", "24", "18", "00"])
    rep.check(ok, "the card shows input_datetime.event as 2026-12-24 18:00", repr(txt))

    mark = time.time()
    if not open_editor(sim, rep, ["2026", "12", "24", "18", "00"], "the editor opens at 2026-12-24 18:00"):
        return
    year = active_box(sim)
    sim.key("up")
    ok, txt = wait_editor(sim, ["2027"])
    rep.check(ok, "up on the year: 2027", repr(txt))
    sim.select()
    month = active_box(sim)
    rep.check(year is not None and month is not None and month["cx"] > year["cx"],
              "select moves to the month", f"{box_str(year)} -> {box_str(month)}")
    rep.shot("editor-2027-month")

    sim.back()
    back1 = active_box(sim)
    rep.check(editor_open(sim), "back on the month stays in the editor")
    rep.check(back1 is not None and month is not None and back1["cx"] < month["cx"],
              "and makes the year active again", f"{box_str(month)} -> {box_str(back1)}")
    ok, txt = wait_editor(sim, ["2027"])
    rep.check(ok, "the edited year is still 2027", repr(txt))
    rep.shot("editor-back-to-year")

    sim.back()
    time.sleep(1.5)
    rep.check(not editor_open(sim), "back on the first field leaves the editor")
    no_service_call(rep, m, mark, "when the editor is cancelled")
    ok, txt = wait_card(sim, ["2026", "12", "24", "18", "00"], absent=["2027"])
    rep.check(ok, "the card still shows 2026-12-24 18:00", repr(txt))
    rep.check(m.state("input_datetime.event") == "2026-12-24 18:00:00", "the mock's state is unchanged",
              m.state("input_datetime.event"))
    rep.shot("card-after-cancel")

    # The year stops at 1970.  Holding down repeats the step (after 400 ms, then every 150 ms, at most
    # 60 times): 61 steps from 2026 would end at 1965 without the clamp.
    if not open_editor(sim, rep, ["2026", "12", "24"], "the editor opens again at 2026-12-24"):
        return
    sim.key("down", hold_ms=11000, settle=1.0)
    ok, txt = wait_editor(sim, ["1970"], absent=["1969", "1965"])
    rep.check(ok, "holding down on the year stops at 1970 (the lower clamp, nothing wraps)", repr(txt))
    rep.shot("editor-year-1970")
    sim.back()
    time.sleep(1.5)
    rep.check(not editor_open(sim), "back on the year leaves the editor")
    no_service_call(rep, m, mark, "after holding down on the year and leaving")
    rep.check(m.state("input_datetime.event") == "2026-12-24 18:00:00", "the mock's state is still unchanged",
              m.state("input_datetime.event"))
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_hold_release", "date and time")
def f7_dt_hold_release(sim, rep):
    """Holding a button repeats the step, and the repeat ends on release.  On time.lunch's minute (00),
    DOWN held for one second steps once on the press, again after 400 ms and then every 150 ms - through
    the wrap to somewhere in 55..59.  The minute read right after the release and 1.5 s later is the
    same.  Back twice leaves without sending anything."""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    mark = time.time()
    if not open_editor(sim, rep, ["12", "00"], "the editor opens at 12:00"):
        return
    w = sim.display_size()[0]
    sim.select()                          # hour -> minute
    minute = active_box(sim)
    rep.check(minute is not None and minute["cx"] > w / 2, "the minute is the active field", box_str(minute))

    sim.key("down", hold_ms=1000, settle=0.0)
    first = rep.shot("right-after-release")
    time.sleep(1.5)
    second = rep.shot("1.5s-later")
    img1, img2 = Image.open(first).convert("RGB"), Image.open(second).convert("RGB")
    t1, t2 = time_row_digits(sim, img1), time_row_digits(sim, img2)
    m1, m2 = _minute_of(t1), _minute_of(t2)
    # Unchanged pixels in the active field prove it without OCR; the readings are the detail.
    box, diff = active_box(sim, img1), None
    if box:
        x0, y0, x1, y1 = box["bbox"]
        a1 = np.asarray(img1.convert("L"), dtype=int)[y0:y1, x0:x1]
        a2 = np.asarray(img2.convert("L"), dtype=int)[y0:y1, x0:x1]
        diff = float(np.abs(a1 - a2).mean())
    rep.check(diff is not None and diff < 2.0 and m1 == m2, "the minute right after the release is still the "
              "minute 1.5 s later (the repeat stops on release)", f"{t1!r} then {t2!r}, pixel difference {diff}")
    rep.check(m2 is not None and 55 <= m2 <= 59, "DOWN held for 1 s went from 00 through the wrap to 55..59 "
              "(a step on the press, a repeat after 400 ms, then every 150 ms)", f"minute {m2}")
    rep.check(re.match(r"\s*12\s*:", t2) is not None, "the hour is still 12 (nothing carries)", repr(t2))

    sim.back()                            # minute -> hour
    sim.back()                            # hour, the first field: leave
    time.sleep(1.5)
    rep.check(not editor_open(sim), "back twice leaves the editor")
    no_service_call(rep, m, mark, "after the hold and back")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_offline_mode", "date and time")
def f7_dt_offline_mode(sim, rep):
    """The stored values carry an offline launch: group.datetime is imported with the phone, then the
    same build is launched again without it (storage kept).  datetime.launch's card still reads
    2026-11-01 14:30 (local), and input_datetime.alarm's editor shows only the time row at 06:30 - no
    year anywhere.  Back leaves; nothing is sent.

    The dtwifi build (Wi-Fi/LTE execution on): there the wait for the phone runs without a loader, so the
    stored entities are on screen offline.  With the plain build "Waiting for connection" covers them,
    and back on it closes the widget on every build tested (see f7_wait_back_to_stored).
    Switches the phone off in the middle - kept after the scenarios that need it on."""
    m = sim.mock_https
    crash_mark = sim.crash_mark()
    exp = launch_expectations()
    wall = exp["wall"]
    since, launched = dt_fresh(sim, m, "dtwifi")
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported with the phone connected")

    sim.set_ble("Not Connected")
    since = time.time()
    sim.push(f"{VARIANTS}/dtwifi-{sim.device}.prg", fresh_settings=True, fresh_storage=False)
    rep.check(sim.launch(), "the widget opened again, without the phone")
    time.sleep(2)
    rep.shot("offline-launch")
    ok, txt = wait_card(sim, ["lunch", "12", "00"])
    rep.check(ok, "offline, the stored entities are shown: time.lunch at 12:00", repr(txt))

    goto(sim, DT_LAUNCH)
    ok, txt = wait_card(sim, [f"{wall:%Y}", f"{wall:%m}", f"{wall:%d}", f"{wall:%H}", f"{wall:%M}"])
    rep.check(ok, f"datetime.launch still reads {wall:%Y-%m-%d %H:%M} (local) offline", repr(txt))
    rep.shot("launch-card-offline")

    log_mark = sim.log_mark()
    sim.next_page()                       # input_datetime.alarm
    time.sleep(1.5)
    if not open_editor(sim, rep, ["06", "30"], "input_datetime.alarm's editor opens at the stored 06:30"):
        return
    txt = editor_text(sim)
    rep.check(re.search(r"(19|20)\d\d", txt) is None, "only the time row: no year anywhere on the editor",
              repr(txt))
    rep.shot("alarm-editor-offline")
    sim.back()                            # the hour is the first field: leave
    time.sleep(1.5)
    rep.check(not editor_open(sim), "back leaves the editor")
    sent = sim.log_since(log_mark)
    rep.check(re.search(r"^(POST|GET|REQUEST): ", sent, re.M) is None,
              "nothing was sent: no request in the app log", repr(sent[-200:]))
    rep.check(not m.requests(since), "and nothing reached Home Assistant", f"{len(m.requests(since))} requests")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_time_12h", "date and time")
def f7_dt_time_12h(sim, rep):
    """The 12-hour clock (the simulator's default; the other scenarios pin the 24-hour one): time.lunch
    shows as 12:00 PM and the editor has an AM/PM field of its own, the last one.  Down on the hour
    stays in the same half of the day (12 PM -> 11 PM), up on AM/PM switches halves (11 AM), and select
    there sends time/set_value {"time": "11:00:00"}.  (Beyond the requested list.)"""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m, clock="12")
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    ok, txt = wait_card(sim, ["12", "00", "PM"])
    rep.check(ok, "the card shows time.lunch as 12:00 PM", repr(txt))

    mark = time.time()
    if not open_editor(sim, rep, ["12", "00", "PM"], "the editor opens at 12:00 PM"):
        return
    w = sim.display_size()[0]
    hour = active_box(sim)
    rep.check(hour is not None and hour["cx"] < w / 2, "the hour is the active field", box_str(hour))
    rep.shot("editor-open")
    sim.key("down")
    ok, txt = wait_editor(sim, ["11", "00", "PM"])
    rep.check(ok, "down on 12 PM gives 11 PM - the hour stays in the same half of the day", repr(txt))
    sim.select()                      # hour -> minute
    minute = active_box(sim)
    sim.select()                      # minute -> AM/PM
    ampm = active_box(sim)
    rep.check(minute is not None and ampm is not None and ampm["cx"] > minute["cx"] + 0.05 * w,
              "select on the minute moves on to the AM/PM field", f"{box_str(minute)} -> {box_str(ampm)}")
    no_service_call(rep, m, mark, "when select reaches AM/PM (on this clock the minute is not the last field)")
    sim.key("up")
    ok, txt = wait_editor(sim, ["11", "00", "AM"])
    rep.check(ok, "up on AM/PM: 11:00 AM", repr(txt))
    rep.shot("editor-11-00-am")
    sim.select()
    call = m.wait_request(r"^/api/services/time/set_value$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "select on AM/PM (the last field) sends time/set_value",
              f"calls: {services_called(m, mark)}")
    check_body(rep, call, {"entity_id": "time.lunch", "time": "11:00:00"},
               'the body is exactly {"time": "11:00:00"} - 24-hour, whatever the display')
    time.sleep(1.5)
    ok, txt = wait_card(sim, ["11", "00", "AM"], timeout=10)
    rep.check(ok, "the card shows 11:00 AM", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_dt_wifi_offer", "date and time")
def f7_dt_wifi_offer(sim, rep):
    """Without the phone and with Wi-Fi/LTE execution on, confirming the editor asks the Wi-Fi/LTE?
    question first, with the value to be sent (14:05) on its second line; Cancel sends nothing.

    Flaky by nature: the phone is switched off while the widget runs, and the simulator's Settings menu
    does not always take at that moment (the README's known limitation) - a failure before the question
    shows needs a retry before it means anything.  Kept last among the fenix 7X scenarios."""
    m = sim.mock_https
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m, "dtwifi")
    rep.check(launched, "the widget opened")
    rep.check(wait_dt_entities(sim, m), "the entities were imported over https with the phone connected")
    sim.set_ble("Not Connected")
    time.sleep(1.5)

    mark = time.time()
    if not open_editor(sim, rep, ["12", "00"], "the editor opens without the phone"):
        return
    for _ in range(2):
        sim.key("up", settle=0.5)     # 14:00
    sim.select()                      # hour -> minute
    for _ in range(5):
        sim.key("up", settle=0.4)     # 14:05
    ok, txt = wait_editor(sim, ["14", "05"])
    rep.check(ok, "edited to 14:05 without the phone", repr(txt))
    sim.select()                      # confirm on the last field
    ok, txt = sim.wait_text(r"wi-?\s*fi|lte", timeout=10)
    rep.shot("wifi-question")
    rep.check(ok, "confirming asks the Wi-Fi/LTE? question instead of sending", repr(txt))
    rep.check(_has(txt, "14") and _has(txt, "05"), "the question shows the value to be sent, 14:05 "
              "(Wi-Fi/LTE? on the first line, the value on the second)", repr(txt))
    no_service_call(rep, m, mark, "while the question is open")
    sim.confirm(False)
    time.sleep(2)
    no_service_call(rep, m, mark, "when the Wi-Fi/LTE question is cancelled")
    rep.shot("after-cancel")
    check_no_crash(rep, sim, crash_mark)


# ============================================================================ venusq2: date and time
@scenario("venusq2", "vq_dt_touch", "date and time")
def vq_dt_touch(sim, rep):
    """Touch, on a watch without up/down: select opens time.lunch; two taps on the "+" band give 14:00,
    a tap on the active hour moves to the minute, five taps give 14:05, a tap on the active minute sends
    time/set_value {"time": "14:05:00"}."""
    _dt_time_touch(sim, rep)


@scenario("venusq2", "vq_dt_touch_field_tap", "date and time")
def vq_dt_touch_field_tap(sim, rep):
    """Touch: a tap on an inactive field makes it the active one without sending anything, the "-" band
    counts down (minute 00 wraps to 59, the hour stays), and a tap on the active last field confirms:
    time.lunch 12:00 -> 12:59.  (Beyond the requested list: covers tap-a-field and the "-" band.)"""
    m = sim.mock
    crash_mark = sim.crash_mark()
    since, launched = dt_fresh(sim, m)
    rep.check(wait_dt_entities(sim, m), "the date/time entities were imported")
    w, h = sim.display_size()
    minus = (w // 2, int(h * (1 - ZONE_FRACTION / 2)))
    mark = time.time()
    if not open_editor(sim, rep, ["12", "00"], "select opens time.lunch at 12:00"):
        return
    hour = active_box(sim)
    rep.check(hour is not None and hour["cx"] < w / 2, "the hour is active", box_str(hour))
    cy = hour["cy"] if hour else h / 2
    point = field_point(sim, 0.8, cy, (hour["h"] / 2) if hour else h * 0.05) or (w / 2 + 0.12 * w, cy)
    rep.shot("editor-open")

    sim.tap(int(point[0]), int(point[1]))
    minute = active_box(sim)
    rep.check(minute is not None and hour is not None and minute["cx"] > hour["cx"] + 0.05 * w,
              "a tap on the minute makes it the active field", f"tap {point}: {box_str(hour)} -> {box_str(minute)}")
    no_service_call(rep, m, mark, "after tapping an inactive field")
    sim.tap(*minus)
    ok, txt = wait_editor(sim, ["12", "59"])
    rep.check(ok, "a tap on the - band: minute 00 wraps to 59, the hour stays 12", repr(txt))
    rep.shot("editor-12-59")

    tap_box(sim, active_box(sim) or minute, point)
    call = m.wait_request(r"^/api/services/time/set_value$", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "a tap on the active minute (the last field) sends time/set_value",
              f"calls: {services_called(m, mark)}")
    check_body(rep, call, {"entity_id": "time.lunch", "time": "12:59:00"},
               'the body is exactly {"time": "12:59:00"}')
    time.sleep(1.5)
    ok, txt = wait_card(sim, ["12", "59"], timeout=10)
    rep.check(ok, "the card shows 12:59", repr(txt))
    rep.shot("card-after")
    check_no_crash(rep, sim, crash_mark)


# ============================================================================ edge1040: date and time
@scenario("edge1040", "e10_dt_touch", "date and time")
def e10_dt_touch(sim, rep):
    """The Edge has neither up/down nor a select button: a tap on the card opens time.lunch, then the
    same touch flow as on the Venu Sq 2 (12:00 -> 14:05, time/set_value {"time": "14:05:00"})."""
    _dt_time_touch(sim, rep)


# ============================================================================ fr255: date and time
@scenario("fr255", "fr_dt_buttons", "date and time")
def fr_dt_buttons(sim, rep):
    """The f7_dt_time_buttons flow on a watch without a touchscreen: up twice, select, up five times,
    select sends time/set_value {"time": "14:05:00"}."""
    _dt_time_buttons(sim, rep)


# ============================================================================ 64 KB: date and time
@scenario("instinct2x", "i2_dt_readonly", "date and time")
def i2_dt_readonly(sim, rep):
    """64 KB: time.lunch is imported over https and shown read-only - selecting it sends nothing and
    does not crash, and memory stays within the budget."""
    _dt_readonly(sim, rep)


@scenario("vivoactive3", "va3_dt_readonly", "date and time")
def va3_dt_readonly(sim, rep):
    """64 KB on Connect IQ 3.1.6: time.lunch is imported over https and shown read-only - selecting it
    sends nothing and does not crash, and memory stays within the budget."""
    _dt_readonly(sim, rep)


# ============================================================================ back on a loader
def _screen_text(sim, img):
    """OCR of the whole display plus, sparse-text, of its middle band at two sizes: the Venu Sq 2's
    loader ("Turning off" in a frame, a busy block sweeping over it) reads as nothing at all otherwise."""
    w, h = sim.display_size()
    band = img.crop((0, int(h * 0.3), w, int(h * 0.7)))
    return "\n".join([sim.ocr(img)] + [sim.ocr(band, scale=s, psm=11) for s in (2, 3)])


def _loader_showing(sim, img, card_img, card_word):
    """Is a loader in front of the card?  The widget runs, the card's text is gone, and either a word of
    the loader is read or the screen clearly differs from the card.  Returns (bool, detail)."""
    txt = _screen_text(sim, img)
    a = np.asarray(img.convert("L"), dtype=int)
    b = np.asarray(card_img.convert("L"), dtype=int)
    diff = float(np.abs(a - b).mean())
    word = re.search(r"tur|ning|toggl|\boff\b", txt, re.I) is not None
    card = re.search(card_word, txt, re.I) is not None
    ok = not no_app(img) and not card and (word or diff > 8.0)
    return ok, f"{txt!r}, differs from the card by {diff:.1f}"


def _loader_back(sim, rep, delay, tap_first=False):
    """Back on a toggle's loader: light.kitchen (on) is turned off while the mock answers `delay` seconds
    late.  Back while "Turning off" shows must take the loader down and leave the card and the widget;
    when the POST completes, nothing else may be popped - the card is still there, with the new state.
    With tap_first a tap on the showing loader comes first, and must do nothing.

    The screenshots are taken at each moment and read afterwards, so that the presses stay well inside
    the delay: a back that came after the loader had gone by itself would leave the widget instead."""
    m = sim.mock_http
    crash_mark = sim.crash_mark()
    since, launched = fresh(sim, m, "base")
    rep.check(launched, "the widget opened")
    rep.check(wait_entities(sim, m), "the entities were imported")
    time.sleep(1.5)
    for _ in range(2):
        sim.next_page()                   # light.kitchen
    time.sleep(1.5)
    ok, txt = sim.wait_text(r"kitchen", timeout=6)
    if not rep.check(ok, "the card shows light.kitchen (on)", repr(txt)):
        snap(sim, rep, "wrong-card")
        return
    before = snap(sim, rep, "card-before")
    w, h = sim.display_size()
    m.delay(delay)
    try:
        mark = time.time()
        sim.select()                      # turn_off; answered `delay` s later
        shown = snap(sim, rep, "loader-shown")
        after_tap = None
        if tap_first:
            sim.tap(w // 2, h // 2, settle=0.4)
            after_tap = snap(sim, rep, "after-tap-on-loader")
        sim.key("esc", settle=0.5)        # back
        after_back = snap(sim, rep, "after-back")
        back_at = time.time()

        ok, detail = _loader_showing(sim, shown, before, r"kitchen")
        rep.check(ok, "selecting shows the loader ('Turning off') in front of the card", detail)
        if tap_first:
            ok, detail = _loader_showing(sim, after_tap, before, r"kitchen")
            rep.check(ok, "a tap on the loader does nothing: it is still there", detail)
        t_back = sim.ocr(after_back)
        call = m.wait_request(r"^/api/services/light/turn_off$", timeout=5, since=mark, method="POST")
        rep.check(call is not None and back_at < call["ts"] + delay,
                  "back came while the request was still unanswered",
                  f"back {round(back_at - call['ts'], 2) if call else None} s after the request, answer after {delay} s")
        rep.check(not no_app(after_back), "after back the widget is still running")
        rep.check(re.search(r"turn|toggl", t_back, re.I) is None, "back takes the loader down", repr(t_back))
        rep.check(re.search(r"kitchen", t_back, re.I) is not None, "and the card is there underneath",
                  repr(t_back))

        if call:
            time.sleep(max(0.0, call["ts"] + delay + 2.5 - time.time()))   # the response and its redraw
        final = snap(sim, rep, "after-the-response")
        t_final = sim.ocr(final)
        rep.check(not no_app(final) and re.search(r"kitchen", t_final, re.I) is not None,
                  "when the POST has completed, the card is still there - nothing else was popped", repr(t_final))
        a = np.asarray(before.convert("L"), dtype=int)
        b = np.asarray(final.convert("L"), dtype=int)
        icon = (slice(int(h * 0.1), int(h * 0.45)), slice(int(w * 0.3), int(w * 0.7)))
        diff = float(np.abs(a[icon] - b[icon]).mean())
        rep.check(diff > 3.0, "and it shows the new state (the light's icon changed)", f"mean pixel difference {diff:.1f}")
        rep.check(m.state("light.kitchen") == "off", "Home Assistant (the mock) turned the light off",
                  m.state("light.kitchen"))
        check_no_crash(rep, sim, crash_mark)
    finally:
        m.delay(0)


@scenario("fenix7x", "f7_loader_back", "loader back")
def f7_loader_back(sim, rep):
    """Back on a toggle's loader (LoaderDelegate): with the mock answering 3 s late, turning off
    light.kitchen and pressing back while "Turning off" shows takes the loader down and leaves the card;
    the response a few seconds later pops nothing else, and the card shows the new state."""
    _loader_back(sim, rep, delay=3)


@scenario("venusq2", "vq_loader_back", "loader back")
def vq_loader_back(sim, rep):
    """As f7_loader_back, on a touch screen: first a tap on the showing loader, which must do nothing,
    then back.  The mock answers 5 s late here - the tap and its screenshot need the extra time before
    the back."""
    _loader_back(sim, rep, delay=5, tap_first=True)


# ============================================================================ entity storage
# The entity list is stored as records of a few entities each, under "Hass/entities/v4/<number>"
# (Hass.STORAGE_KEY).  Releases up to 2.3.0 wrote one Array for the whole list - "Hass/entities/v3" on
# full-memory devices, "Hass/entities/v2" on 64 KB ones - and the first launch after the update turns
# that into records.  A write of the whole list needed more free memory the longer the list was, and
# an Out Of Memory error cannot be caught: past some two dozen entities every refresh on a 64 KB
# watch ended in a crash.
#
# Builds: base-<device>.prg, and v230-<device>.prg from build-master.sh (release 2.3.0, the last one
# that stored the list as one array, pointed at the mock).
def state_gets(mock, since):
    """The entity ids (group included) the widget asked the mock for since `since`, in order."""
    return [e["path"].rsplit("/", 1)[-1] for e in mock.requests(since)
            if e["method"] == "GET" and "/api/states/" in e["path"]]


def wait_quiet(mock, since, quiet=5, limit=120, idle=20):
    """Wait until the widget has stopped sending requests (or, after `idle` s, never sent any)."""
    last, mark, start = -1, time.time(), time.time()
    while time.time() - start < limit:
        n = len(mock.requests(since))
        if n != last:
            last, mark = n, time.time()
        elif time.time() - mark > (quiet if n else idle):
            return n
        time.sleep(0.5)
    return last


def stored_keys(sim):
    """The keys of the entity list that were ever written to the simulator's copy of
    Application.Storage.  APP.DAT keeps the key strings readable - and keeps them after a value is
    replaced or deleted, so this tells that a key was written, never that one is gone."""
    try:
        data = open(sim.app_files()["dat"], "rb").read()
    except FileNotFoundError:
        return set()
    return {k.decode() for k in re.findall(rb"Hass/entities(?:/v\d+(?:/\d+)?)?", data)}


def relaunch_on_storage(sim, mock, variant="base"):
    """Start a build on the storage that is there; returns what it asked the mock for."""
    since = time.time()
    sim.push(f"{VARIANTS}/{variant}-{sim.device}.prg", fresh_settings=True, fresh_storage=False)
    launched = sim.launch()
    wait_quiet(mock, since)
    time.sleep(3)                       # the list is stored a moment after the last response
    return launched, state_gets(mock, since)


def _storage_upgrade(sim, rep, mock, old_key):
    """Release 2.3.0 imports the group and stores it its way; the current build then starts on that
    storage, must load the list without importing it again, and must leave it behind as records.  The
    2.3.0 build talks to the TLS mock on every device (it knows no plain http), the current one to
    `mock`."""
    crash_mark = sim.crash_mark()
    old = f"{VARIANTS}/v230-{sim.device}.prg"
    if not os.path.exists(old):
        rep.check(False, "the build of release 2.3.0 is available (build-master.sh)", old)
        return
    old_mock = sim.mock_https
    old_mock.reset()
    mock.reset()
    since = time.time()
    sim.push(old)
    sim.launch()
    rep.check(wait_entities(sim, old_mock), "2.3.0 imported the group")
    wait_quiet(old_mock, since)
    time.sleep(3)
    keys = stored_keys(sim)
    rep.check(old_key in keys, f"2.3.0 stored the list under {old_key}", str(sorted(keys)))
    rep.shot("2.3.0")

    launched, gets = relaunch_on_storage(sim, mock)
    rep.check(launched, "the current build starts on the storage of 2.3.0")
    rep.check("group.garmin" not in gets, "the stored list was loaded: the group was not imported again",
              str(gets[:3]))
    rep.check(sorted(gets) == sorted(ENTITIES), "every entity of the list was refreshed, each once",
              f"{len(gets)} requests for {len(set(gets))} of {len(ENTITIES)} entities")
    if sim.device not in LOWMEM:        # debug builds say what they loaded
        rep.check(sim.wait_log(rf"Migrated entities: {len(ENTITIES)} total", timeout=3) is not None,
                  f"the app log reports {len(ENTITIES)} migrated entities")
    keys = stored_keys(sim)
    rep.check("Hass/entities/v4/0" in keys, "the list is stored as records now", str(sorted(keys)))
    rep.shot("after-the-update")

    launched, gets = relaunch_on_storage(sim, mock)
    rep.check("group.garmin" not in gets and sorted(gets) == sorted(ENTITIES),
              "the records load at the next launch, again without an import",
              f"{len(gets)} requests, group import: {'group.garmin' in gets}")
    if sim.device not in LOWMEM:
        rep.check(sim.wait_log(rf"Loaded entities: {len(ENTITIES)} total", timeout=3) is not None,
                  f"the app log reports {len(ENTITIES)} loaded entities")

    # The old key is gone: 2.3.0, started once more on this storage, finds no list of its own and
    # imports the group.  (The storage file cannot tell - it keeps the bytes of deleted values.)  It
    # also shows what a step back to the older release does: an import, not a crash.
    since = time.time()
    sim.push(old, fresh_settings=True, fresh_storage=False)
    sim.launch()
    back = old_mock.wait_request(r"group\.garmin", timeout=25, since=since) is not None
    rep.check(back, f"{old_key} is gone: 2.3.0 finds no list on this storage and imports the group")
    wait_quiet(old_mock, since)
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_storage_upgrade", "entity storage")
def f7_storage_upgrade(sim, rep):
    """A full-memory watch updated from 2.3.0: the list stored as one ten-slot Array ("Hass/entities/v3")
    is loaded, written as records and its old key removed - no "No entities configured", no new import."""
    _storage_upgrade(sim, rep, sim.mock_http, "Hass/entities/v3")


@scenario("instinct2x", "i2_storage_upgrade", "entity storage")
def i2_storage_upgrade(sim, rep):
    """The same on a 64 KB watch, whose list is one six-slot Array under "Hass/entities/v2"."""
    _storage_upgrade(sim, rep, sim.mock_https, "Hass/entities/v2")


def _refresh_entities_from_menu(sim):
    """Menu > Settings > Refresh entities, on a 64 KB watch (whose Settings menu has no list view
    switch above that entry)."""
    sim.key("menu", hold_ms=1300)
    time.sleep(1.2)
    for _ in range(3):                  # Scenes, Entities, Entities&Scenes, Settings
        sim.key("down")
    sim.key("enter")
    time.sleep(1.2)
    sim.key("down")                     # Start View, Refresh entities
    sim.key("enter")


@scenario("instinct2x", "i2_reimport_sizes", "entity storage")
def i2_reimport_sizes(sim, rep):
    """The group changes size across the boundaries of the stored records (4 entities each on this
    tier), down to nothing and back, and loses a member from its middle.  After every import the next
    launch must ask for exactly the entities of the group, each once: no record of the longer list
    before it may be left behind, and none missing."""
    m = sim.mock_https
    crash_mark = sim.crash_mark()
    m.reset()
    lists = [("13 entities", ENTITIES[:13]),
             ("12 entities", ENTITIES[:12]),
             ("5 entities", ENTITIES[:5]),
             ("4 entities", ENTITIES[:4]),
             ("an empty group", []),
             ("13 entities again", ENTITIES[:13]),
             ("one removed from the middle", ENTITIES[:3] + ENTITIES[4:13])]
    for i, (label, ids) in enumerate(lists):
        m.set("group.garmin", "on", {"entity_id": ids})
        since = time.time()
        if i == 0:
            sim.push(f"{VARIANTS}/base-{sim.device}.prg")
            sim.launch()
        else:
            _refresh_entities_from_menu(sim)
        imported = m.wait_request(r"group\.garmin", timeout=25, since=since) is not None
        rep.check(imported, f"{label}: the group was imported")
        wait_quiet(m, since)
        time.sleep(3)
        if not imported:
            rep.shot(f"no-import-{i}")

        _, gets = relaunch_on_storage(sim, m)
        if ids:
            rep.check("group.garmin" not in gets, f"{label}: the next launch loads the stored list",
                      str(gets[:3]))
            rep.check(gets == ids, f"{label}: it asks for exactly these entities, in order",
                      f"asked for {len(gets)}: {gets}")
        else:
            # Nothing stored but an empty record: the launch imports the group, as on a first launch.
            rep.check(gets == ["group.garmin"], f"{label}: the next launch has no entities and imports",
                      str(gets))
    rep.shot("after-the-last-import")
    check_no_crash(rep, sim, crash_mark)


# ============================================================================ glance
# The glance draws only its text; the firmware paints the stripe behind it.  Watches paint it dark.
# The Edge units paint it white in their Day display mode, where the white text of 2.3.0 could not be
# seen (issue #108).  The text follows DeviceSettings.isNightModeEnabled on the devices that have it.
# The simulator does not paint the white stripe - its glance page stays black in both modes - so the
# check is the colour of the text: light pixels beside the icon, or none.
def glance_text_pixels(sim):
    """Light pixels in the glance list, right of the launcher icon (the text "HassControl" when it is
    drawn in white; the icon itself is left out)."""
    img = np.asarray(sim.display_shot().convert("L"))
    h, w = img.shape
    return int((img[:, int(w * 0.30):] > 180).sum())


def toggle_night_mode(sim):
    sim.menu("Settings", "Night Mode")
    time.sleep(2.5)


@scenario("edge1040", "e10_glance_day_night", "glance")
def e10_glance_day_night(sim, rep):
    """Issue #108: on an Edge in Day mode the glance text must be dark, in Night mode light - and it must
    follow when the mode changes while the glance is on screen (HassControlApp.onNightModeChanged())."""
    crash_mark = sim.crash_mark()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    time.sleep(3)
    rep.check(not sim.running(), "the glance list is showing, not the widget")
    day = glance_text_pixels(sim)
    rep.shot("day")
    rep.check(day < 20, "Day mode: the text is not white", f"{day} light pixels")
    toggle_night_mode(sim)
    try:
        night = glance_text_pixels(sim)
        rep.shot("night")
        rep.check(night > 150, "Night mode: the text is white, without a new launch", f"{night} light pixels")
    finally:
        toggle_night_mode(sim)          # the scenarios after this one expect Day mode
    again = glance_text_pixels(sim)
    rep.shot("day-again")
    rep.check(again < 20, "back in Day mode the text is dark again", f"{again} light pixels")
    check_no_crash(rep, sim, crash_mark)


@scenario("fenix7x", "f7_glance_text", "glance")
def f7_glance_text(sim, rep):
    """A watch has no Day mode: its glance stripe is dark and the text stays white."""
    crash_mark = sim.crash_mark()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    time.sleep(3)
    rep.check(not sim.running(), "the glance list is showing, not the widget")
    light = glance_text_pixels(sim)
    rep.shot("glance")
    rep.check(light > 150, "the glance text is white", f"{light} light pixels")
    check_no_crash(rep, sim, crash_mark)
