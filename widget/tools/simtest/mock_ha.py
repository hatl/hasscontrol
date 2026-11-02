#!/usr/bin/env python3
"""Minimal Home Assistant REST API mock for simulator tests of the HassControl widget.

usage: mock_ha.py [--port 8123] [--token TESTTOKEN] [--delay 0.0] [--logfile mock/requests.jsonl]
                  [--transition 3.0]  # seconds a lock/cover stays in locking/opening before settling

Endpoints (HA-compatible):
  GET  /api/states/<entity_id>            -> state object (404 if unknown); group.* carries attributes.entity_id
  POST /api/services/<domain>/<service>   -> applies the action, returns [] (the date/time services below
                                             return the changed state, as Home Assistant does)
  POST /api/states/<entity_id>            -> upsert (battery report)
  POST /auth/token                        -> OAuth token response (any code/refresh token accepted)
Control endpoints (no auth):
  GET  /_test/log      -> JSON list of every request seen (ts, method, path, body, auth)
  POST /_test/reset    -> reset state to the fixture and clear the log
  POST /_test/fail     -> body {"code": 401, "count": 1}: the next <count> API requests fail with <code>
  GET  /_test/state    -> all entity states
  POST /_test/set      -> body {"entity_id": ..., "state": ...}: force a state (e.g. to simulate an external change)
  POST /_test/delay    -> body {"seconds": 3}: every /api/ request is answered that much later (0 clears it;
                          /_test/reset clears it too) - keeps a loader on screen
Every log entry also carries the HTTP "status" the mock answered with.

Groups: group.garmin (the original fixture - its order is what the older scenarios navigate by),
group.datetime (time.lunch, date.deadline, datetime.launch, input_datetime.alarm/.vacation/.event) and
group.all (both, plus number/select/input_button - every supported type, for exploratory sessions).

Date and time services, validated the way Home Assistant validates them (400 on bad service data):
  time.set_value {"time"}, date.set_value {"date"}, datetime.set_value {"datetime"} (stored exactly as sent),
  input_datetime.set_datetime {"date"} | {"time"} | {"datetime"} - only the keys the entity has
  (has_date/has_time); "datetime" needs both and cannot be combined with the others.
  Missing or unknown keys -> 400 (HA's entity service schemas allow no extra keys).  An entity id of
  another domain is ignored with 200 and nothing changed, as HA does.
"""
import argparse, json, threading, time, sys, copy, os, re
import datetime as _dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class BadRequest(Exception):
    """Service data Home Assistant refuses with 400."""


def _parse_date(value):
    # HA: cv.date -> dt_util.parse_date(), strptime("%Y-%m-%d")
    try:
        return _dt.datetime.strptime(str(value), "%Y-%m-%d").date()
    except ValueError:
        raise BadRequest(f"Invalid date specified: {value!r}")


def _parse_time(value):
    # HA: cv.time -> dt_util.parse_time(), "HH:MM" or "HH:MM:SS"
    parts = str(value).split(":")
    try:
        if len(parts) not in (2, 3):
            raise ValueError
        return _dt.time(*(int(p) for p in parts))
    except ValueError:
        raise BadRequest(f"Invalid time specified: {value!r}")


def _parse_datetime(value):
    # HA: cv.datetime -> dt_util.parse_datetime(): ISO 8601 with "T" or " ", optional offset.  A bare
    # date is refused here (HA would read it as midnight) - nothing the widget sends looks like that.
    s = str(value)
    try:
        if not re.match(r"^\d{4}-\d{1,2}-\d{1,2}[T ]\d{1,2}:\d{2}", s):
            raise ValueError
        return _dt.datetime.fromisoformat(s)
    except ValueError:
        raise BadRequest(f"Invalid datetime specified: {value!r}")


def _input_datetime_value(state, has_date, has_time):
    """The naive datetime behind an input_datetime state (now, if the state is not one)."""
    try:
        if has_date and has_time:
            return _dt.datetime.strptime(state, "%Y-%m-%d %H:%M:%S")
        if has_date:
            return _dt.datetime.strptime(state, "%Y-%m-%d")
        return _dt.datetime.combine(_dt.date(1970, 1, 1), _dt.datetime.strptime(state, "%H:%M:%S").time())
    except (TypeError, ValueError):
        return _dt.datetime.now().replace(microsecond=0)


def _input_datetime_state(value, has_date, has_time):
    if has_date and has_time:
        return value.strftime("%Y-%m-%d %H:%M:%S")
    return value.strftime("%Y-%m-%d") if has_date else value.strftime("%H:%M:%S")


def _input_datetime_attrs(value, has_date, has_time):
    """The attributes HA's input_datetime reports alongside its state (local time zone)."""
    attrs = {"has_date": has_date, "has_time": has_time, "editable": True}
    if has_date:
        attrs.update(year=value.year, month=value.month, day=value.day)
    if has_time:
        attrs.update(hour=value.hour, minute=value.minute, second=value.second)
    if not has_date:
        attrs["timestamp"] = value.hour * 3600 + value.minute * 60 + value.second
    elif not has_time:
        attrs["timestamp"] = _dt.datetime.combine(value.date(), _dt.time()).timestamp()
    else:
        attrs["timestamp"] = value.timestamp()
    return attrs


def _input_datetime(name, state, has_date, has_time):
    value = _input_datetime_value(state, has_date, has_time)
    return {"state": state, "attributes": {"friendly_name": name, **_input_datetime_attrs(value, has_date, has_time)}}


# The data keys each date/time service takes besides entity_id.
DT_SERVICES = {("time", "set_value"): {"time"}, ("date", "set_value"): {"date"},
               ("datetime", "set_value"): {"datetime"},
               ("input_datetime", "set_datetime"): {"date", "time", "datetime"}}
DT_DOMAINS = {d for d, _ in DT_SERVICES}


FIXTURE = {
    "group.garmin": {"state": "on", "attributes": {"friendly_name": "Garmin", "entity_id": [
        "lock.front_door", "cover.garage", "light.kitchen", "switch.tv", "scene.movie", "script.goodnight",
        "input_number.volume", "input_select.mode", "sensor.temperature", "binary_sensor.door",
        "button.restart", "automation.lights", "fan.bedroom", "valve.water", "input_boolean.guest"]}},
    "lock.front_door": {"state": "locked", "attributes": {"friendly_name": "Front Door"}},
    "cover.garage": {"state": "closed", "attributes": {"friendly_name": "Garage", "device_class": "garage"}},
    "light.kitchen": {"state": "on", "attributes": {"friendly_name": "Kitchen", "icon": "mdi:ceiling-light"}},
    "switch.tv": {"state": "off", "attributes": {"friendly_name": "TV"}},
    "scene.movie": {"state": "scening", "attributes": {"friendly_name": "Movie"}},
    "script.goodnight": {"state": "off", "attributes": {"friendly_name": "Good Night"}},
    "input_number.volume": {"state": "40.0", "attributes": {"friendly_name": "Volume", "min": 0, "max": 100, "step": 5, "mode": "slider"}},
    "input_select.mode": {"state": "Home", "attributes": {"friendly_name": "Mode", "options": ["Home", "Away", "Night"]}},
    "sensor.temperature": {"state": "21.5", "attributes": {"friendly_name": "Temperature", "unit_of_measurement": "°C", "device_class": "temperature"}},
    "binary_sensor.door": {"state": "off", "attributes": {"friendly_name": "Door", "device_class": "door"}},
    "button.restart": {"state": "2026-01-01T00:00:00+00:00", "attributes": {"friendly_name": "Restart"}},
    "automation.lights": {"state": "on", "attributes": {"friendly_name": "Lights automation"}},
    "fan.bedroom": {"state": "off", "attributes": {"friendly_name": "Bedroom fan"}},
    "valve.water": {"state": "open", "attributes": {"friendly_name": "Water valve"}},
    "input_boolean.guest": {"state": "off", "attributes": {"friendly_name": "Guest mode"}},
    # A group of its own for the date and time entities, so group.garmin keeps its order.
    "group.datetime": {"state": "on", "attributes": {"friendly_name": "Date and time", "entity_id": [
        "time.lunch", "date.deadline", "datetime.launch", "input_datetime.alarm", "input_datetime.vacation",
        "input_datetime.event"]}},
    "time.lunch": {"state": "12:00:00", "attributes": {"friendly_name": "Lunch"}},
    "date.deadline": {"state": "2026-01-31", "attributes": {"friendly_name": "Deadline"}},
    "datetime.launch": {"state": "2026-11-01T13:30:00+00:00", "attributes": {"friendly_name": "Launch"}},
    "input_datetime.alarm": _input_datetime("Alarm", "06:30:00", has_date=False, has_time=True),
    "input_datetime.vacation": _input_datetime("Vacation", "2026-07-01", has_date=True, has_time=False),
    "input_datetime.event": _input_datetime("Event", "2026-12-24 18:00:00", has_date=True, has_time=True),
    # Every entity type the widget supports in one group, for exploratory sessions (live.py): the two
    # groups above plus the domains they lack (input_button, select, number).
    "group.all": {"state": "on", "attributes": {"friendly_name": "Everything", "entity_id": [
        "lock.front_door", "cover.garage", "light.kitchen", "switch.tv", "scene.movie", "script.goodnight",
        "input_number.volume", "number.brightness", "input_select.mode", "select.scene_mode",
        "sensor.temperature", "binary_sensor.door", "button.restart", "input_button.ring",
        "automation.lights", "fan.bedroom", "valve.water", "input_boolean.guest",
        "time.lunch", "date.deadline", "datetime.launch", "input_datetime.alarm", "input_datetime.vacation",
        "input_datetime.event"]}},
    "number.brightness": {"state": "75.0", "attributes": {"friendly_name": "Brightness", "min": 0, "max": 255, "step": 1, "mode": "auto"}},
    "select.scene_mode": {"state": "Relax", "attributes": {"friendly_name": "Scene mode", "options": ["Relax", "Focus", "Party"]}},
    "input_button.ring": {"state": "2026-01-01T00:00:00+00:00", "attributes": {"friendly_name": "Ring"}},
}

class Store:
    def __init__(self, transition):
        self.lock = threading.Lock(); self.transition = transition; self.generation = 0; self.reset()
    def reset(self):
        # Bump the generation so transitions still pending from before the reset (a lock settling
        # from "unlocking" to "unlocked" three seconds later, say) do not write over the fresh
        # fixture - that leaked state from one test scenario into the next.
        with self.lock:
            self.generation += 1
            self.states = copy.deepcopy(FIXTURE); self.log = []; self.fail = None; self.delay = 0.0
    def record(self, entry):
        with self.lock: self.log.append(entry)
    def get(self, eid):
        with self.lock:
            s = self.states.get(eid)
            if s is None: return None
            return {"entity_id": eid, "state": s["state"], "attributes": s["attributes"],
                    "last_changed": "2026-11-01T00:00:00+00:00", "last_updated": "2026-11-01T00:00:00+00:00"}
    def set(self, eid, state, attrs=None):
        with self.lock:
            e = self.states.setdefault(eid, {"state": None, "attributes": {}})
            e["state"] = state
            if attrs: e["attributes"].update(attrs)
    def settle_later(self, eid, final):
        generation = self.generation
        def go():
            time.sleep(self.transition)
            with self.lock:
                if generation != self.generation:
                    return          # a reset happened in between: this transition is stale
            self.set(eid, final)
        threading.Thread(target=go, daemon=True).start()
    def service(self, domain, service, body):
        if domain in DT_DOMAINS:
            return self.datetime_service(domain, service, body)
        eid = (body or {}).get("entity_id")
        cur = self.get(eid)["state"] if eid and self.get(eid) else None
        if domain == "lock":
            if service == "lock": self.set(eid, "locking"); self.settle_later(eid, "locked")
            elif service == "unlock": self.set(eid, "unlocking"); self.settle_later(eid, "unlocked")
        elif domain in ("cover", "valve"):
            target = {"open_cover": "open", "close_cover": "closed", "open": "open", "close": "closed"}.get(service)
            if service in ("toggle", "toggle_cover"): target = "closed" if cur in ("open", "opening") else "open"
            if target:
                self.set(eid, "opening" if target == "open" else "closing"); self.settle_later(eid, target)
        elif domain in ("light", "switch", "fan", "input_boolean", "automation"):
            if service == "turn_on": self.set(eid, "on")
            elif service == "turn_off": self.set(eid, "off")
            elif service == "toggle": self.set(eid, "off" if cur == "on" else "on")
        elif domain in ("button", "input_button"):
            self.set(eid, time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()))
        elif domain in ("input_select", "select"):
            if service == "select_option": self.set(eid, body.get("option"))
        elif domain in ("input_number", "number"):
            if service == "set_value": self.set(eid, str(float(body.get("value"))))
        elif domain in ("scene", "script"):
            pass
        return []
    def datetime_service(self, domain, service, body):
        """time/date/datetime.set_value and input_datetime.set_datetime.  Raises BadRequest where HA
        answers 400; returns the changed states, as HA's REST API does."""
        allowed = DT_SERVICES.get((domain, service))
        if allowed is None:
            raise BadRequest(f"Service {domain}.{service} not found")
        if not isinstance(body, dict) or not body.get("entity_id"):
            raise BadRequest("must contain at least one of entity_id, device_id, area_id")
        extra = set(body) - allowed - {"entity_id"}
        if extra:
            raise BadRequest(f"extra keys not allowed: {sorted(extra)}")
        given = set(body) & allowed
        if not given:
            raise BadRequest(f"must contain at least one of {sorted(allowed)}")
        eid = body["entity_id"]
        with self.lock:
            entity = copy.deepcopy(self.states.get(eid))
        if entity is None or not str(eid).startswith(domain + "."):
            # HA only calls an entity service on that domain's entities: any other id is ignored, and
            # the call still answers 200 - with nothing changed.
            return []
        old, attrs = entity["state"], None
        if domain == "time":
            new = _parse_time(body["time"]).isoformat()
        elif domain == "date":
            new = _parse_date(body["date"]).isoformat()
        elif domain == "datetime":
            _parse_datetime(body["datetime"])
            new = str(body["datetime"])          # stored exactly as sent (HA would convert it to UTC)
        else:
            has_date = bool(entity["attributes"].get("has_date"))
            has_time = bool(entity["attributes"].get("has_time"))
            if "datetime" in given and len(given) > 1:
                raise BadRequest(f"Cannot use together: {', '.join(sorted(given))}")
            if ("date" in given and not has_date) or ("time" in given and not has_time) \
                    or ("datetime" in given and not (has_date and has_time)):
                raise BadRequest(f"{eid} has_date={has_date} has_time={has_time} cannot take {sorted(given)}")
            if "datetime" in given:
                value = _parse_datetime(body["datetime"]).replace(tzinfo=None, microsecond=0)
            else:
                current = _input_datetime_value(old, has_date, has_time)
                d = _parse_date(body["date"]) if "date" in given else current.date()
                t = _parse_time(body["time"]) if "time" in given else current.time()
                value = _dt.datetime.combine(d, t)
            new = _input_datetime_state(value, has_date, has_time)
            attrs = _input_datetime_attrs(value, has_date, has_time)
        self.set(eid, new, attrs)
        return [self.get(eid)] if new != old else []

class Handler(BaseHTTPRequestHandler):
    store = None; token = None; delay = 0.0
    def log_message(self, fmt, *args):  # quiet
        pass
    def _send(self, code, obj=None):
        entry = getattr(self, "_entry", None)
        if entry is not None:
            entry["status"] = code      # what the widget got back, for the scenario reports
        data = (json.dumps(obj) if obj is not None else "").encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try: return json.loads(raw) if raw else None
        except Exception: return raw.decode(errors="replace")
    def _auth_ok(self):
        return self.headers.get("Authorization") == "Bearer " + self.token
    def _handle(self):
        body = self._body()
        auth = self._auth_ok()
        # "status" exists from the start: _send() fills it in later, and adding a key then could break a
        # /_test/log that is serialising this entry at that moment.
        self._entry = {"ts": round(time.time(), 3), "method": self.command, "path": self.path, "body": body, "auth": auth,
                       "headers": {k: v for k, v in self.headers.items() if k.lower() in ("authorization", "x-custom-psk", "content-type")},
                       "status": None}
        self.store.record(self._entry)
        sys.stdout.write(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} auth={auth} body={body}\n"); sys.stdout.flush()
        if self.path.startswith("/_test/"):
            return self._control(body)
        if self.delay: time.sleep(self.delay)
        if self.store.delay and self.path.startswith("/api/"): time.sleep(self.store.delay)
        if self.path == "/auth/token" and self.command == "POST":
            return self._send(200, {"access_token": self.token, "token_type": "Bearer", "refresh_token": "REFRESH", "expires_in": 1800})
        with self.store.lock:
            f = self.store.fail
            if f and f["count"] > 0 and self.path.startswith("/api/"):
                f["count"] -= 1; code = f["code"]
                if f["count"] == 0: self.store.fail = None
                return self._send(code, {"message": "forced failure"})
        if not auth:
            return self._send(401, {"message": "Unauthorized"})
        parts = self.path.split("?")[0].strip("/").split("/")
        if len(parts) == 3 and parts[0] == "api" and parts[1] == "states":
            if self.command == "GET":
                st = self.store.get(parts[2])
                return self._send(200, st) if st else self._send(404, {"message": "Entity not found."})
            if self.command == "POST":
                self.store.set(parts[2], str((body or {}).get("state")), (body or {}).get("attributes"))
                return self._send(200, self.store.get(parts[2]))
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "services" and self.command == "POST":
            try:
                return self._send(200, self.store.service(parts[2], parts[3], body))
            except BadRequest as e:
                sys.stdout.write(f"{time.strftime('%H:%M:%S')}   -> 400 {e}\n"); sys.stdout.flush()
                return self._send(400, {"message": str(e)})
        return self._send(404, {"message": "not found"})
    def _control(self, body):
        if self.path == "/_test/log":
            with self.store.lock: snapshot = list(self.store.log)
            return self._send(200, snapshot)
        if self.path == "/_test/reset": self.store.reset(); return self._send(200, {"ok": True})
        if self.path == "/_test/state": return self._send(200, self.store.states)
        if self.path == "/_test/fail":
            with self.store.lock: self.store.fail = {"code": int(body.get("code", 500)), "count": int(body.get("count", 1))}
            return self._send(200, {"ok": True})
        if self.path == "/_test/delay":
            with self.store.lock: self.store.delay = max(0.0, float((body or {}).get("seconds", 0)))
            return self._send(200, {"ok": True, "delay": self.store.delay})
        if self.path == "/_test/set":
            self.store.set(body["entity_id"], body["state"], body.get("attributes")); return self._send(200, {"ok": True})
        return self._send(404, {"message": "unknown control endpoint"})
    do_GET = _handle; do_POST = _handle; do_PUT = _handle; do_DELETE = _handle

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--port", type=int, default=8123); ap.add_argument("--token", default="TESTTOKEN")
    ap.add_argument("--delay", type=float, default=0.0); ap.add_argument("--transition", type=float, default=3.0)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--cert", default=None); ap.add_argument("--key", default=None)  # serve https when given
    a = ap.parse_args()
    Handler.store = Store(a.transition); Handler.token = a.token; Handler.delay = a.delay
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    scheme = "http"
    if a.cert:
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(a.cert, a.key or a.cert)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True); scheme = "https"
    print(f"mock HA listening on {scheme}://{a.bind}:{a.port} token={a.token} delay={a.delay}s transition={a.transition}s", flush=True)
    srv.serve_forever()

if __name__ == "__main__": main()
