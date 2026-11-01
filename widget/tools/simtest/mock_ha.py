#!/usr/bin/env python3
"""Minimal Home Assistant REST API mock for simulator tests of the HassControl widget.

usage: mock_ha.py [--port 8123] [--token TESTTOKEN] [--delay 0.0] [--logfile mock/requests.jsonl]
                  [--transition 3.0]  # seconds a lock/cover stays in locking/opening before settling

Endpoints (HA-compatible):
  GET  /api/states/<entity_id>            -> state object (404 if unknown); group.* carries attributes.entity_id
  POST /api/services/<domain>/<service>   -> applies the action, returns []
  POST /api/states/<entity_id>            -> upsert (battery report)
  POST /auth/token                        -> OAuth token response (any code/refresh token accepted)
Control endpoints (no auth):
  GET  /_test/log      -> JSON list of every request seen (ts, method, path, body, auth)
  POST /_test/reset    -> reset state to the fixture and clear the log
  POST /_test/fail     -> body {"code": 401, "count": 1}: the next <count> API requests fail with <code>
  GET  /_test/state    -> all entity states
  POST /_test/set      -> body {"entity_id": ..., "state": ...}: force a state (e.g. to simulate an external change)
"""
import argparse, json, threading, time, sys, copy, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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
            self.states = copy.deepcopy(FIXTURE); self.log = []; self.fail = None
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

class Handler(BaseHTTPRequestHandler):
    store = None; token = None; delay = 0.0
    def log_message(self, fmt, *args):  # quiet
        pass
    def _send(self, code, obj=None):
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
        self.store.record({"ts": round(time.time(), 3), "method": self.command, "path": self.path, "body": body, "auth": auth,
                           "headers": {k: v for k, v in self.headers.items() if k.lower() in ("authorization", "x-custom-psk", "content-type")}})
        sys.stdout.write(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} auth={auth} body={body}\n"); sys.stdout.flush()
        if self.path.startswith("/_test/"):
            return self._control(body)
        if self.delay: time.sleep(self.delay)
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
            return self._send(200, self.store.service(parts[2], parts[3], body))
        return self._send(404, {"message": "not found"})
    def _control(self, body):
        if self.path == "/_test/log": return self._send(200, self.store.log)
        if self.path == "/_test/reset": self.store.reset(); return self._send(200, {"ok": True})
        if self.path == "/_test/state": return self._send(200, self.store.states)
        if self.path == "/_test/fail":
            with self.store.lock: self.store.fail = {"code": int(body.get("code", 500)), "count": int(body.get("count", 1))}
            return self._send(200, {"ok": True})
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
