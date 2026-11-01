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
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ciqsim import Sim, Mock, Report, MOCK_HTTP, MOCK_HTTPS, S, VARIANTS, log

MASTER_PRG = S + "/out/master-fenix7x-debug.prg"

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


@scenario("fenix7x", "f7_lock_yesno", "lock confirmation")
def f7_lock_yesno(sim, rep):
    """Yes/no mode: Cancel sends nothing and leaves the lock alone, Confirm unlocks it."""
    m = sim.mock_http
    m.reset()
    m.set("lock.front_door", "locked")       # start from a known state, whatever ran before
    since, _ = fresh(sim, m, "lockyn")
    wait_entities(sim, m)
    rep.check(m.state("lock.front_door") == "locked", "the door starts locked",
              m.state("lock.front_door"))

    mark = time.time()
    sim.select()
    time.sleep(1.5)
    ok, txt = sim.wait_text(r"front\s*door", timeout=8)
    rep.check(ok, "a question about the door is shown", repr(txt))
    head = sim.header_text()
    rep.check(re.search(r"unlock", head, re.I) is not None,
              "the question is 'Unlock Front Door?'", repr(head))
    rep.shot("question")

    sim.confirm(False)
    time.sleep(2.0)
    no_service_call(rep, m, mark, "when the question is cancelled")
    rep.check(m.state("lock.front_door") == "locked", "the door is still locked after Cancel",
              m.state("lock.front_door"))
    rep.shot("after-cancel")

    mark = time.time()
    sim.select()
    time.sleep(1.5)
    sim.confirm(True)
    call = m.wait_request("lock/unlock", timeout=10, since=mark, method="POST")
    rep.check(call is not None, "confirming sends lock/unlock",
              f"calls: {services_called(m, mark)}")
    time.sleep(4)
    rep.check(m.state("lock.front_door") == "unlocked", "the door ends up unlocked",
              m.state("lock.front_door"))
    rep.shot("after-confirm")


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

    The master build is pushed first so the simulator stores its settings, then the branch build runs
    on top of them without clearing them."""
    m = sim.mock_http
    m.reset()
    if not os.path.exists(MASTER_PRG):
        rep.check(False, "the master build is available", MASTER_PRG)
        return
    sim.set_ble("Connected")
    sim.push(MASTER_PRG)
    sim.launch()
    time.sleep(6)
    rep.shot("master-running")

    crash_mark = sim.crash_mark()
    sim.push(f"{VARIANTS}/base-{sim.device}.prg", fresh_settings=False, fresh_storage=False)
    launched = sim.launch()
    rep.check(launched, "the branch build starts on settings written by the old build")
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

    Checked side by side with a build of master in this same scenario, because the only change meant
    for this tier is the timer fix."""
    m = sim.mock_https
    m.reset()
    sim.set_ble("Connected")
    sim.push(f"{VARIANTS}/base-{sim.device}.prg")
    sim.launch()
    rep.check(wait_entities(sim, m), "the entities were imported with the phone connected")
    sim.set_ble("Not Connected")

    seen = {}
    for tag, prg in (("master", "master"), ("branch", "base")):
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

    rep.check(seen["master"][2] == seen["branch"][2],
              "master and the branch run under the same memory budget",
              f"master {seen['master'][1]}/{seen['master'][2]} kB, branch {seen['branch'][1]}/{seen['branch'][2]} kB")
    sim.note(f"memory without the phone: master {seen['master'][1]} kB, branch {seen['branch'][1]} kB "
             f"of {seen['branch'][2]} kB")
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
