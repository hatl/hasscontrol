#!/usr/bin/env python3
"""How many entities does a build hold on a device - and what happens beyond that?

    uv run capacity.py instinct2x 12 18 24 28            n switches each
    uv run capacity.py instinct2x 24 --mixed             every supported type, repeated up to n
    uv run capacity.py instinct2x 24 --ref master        a build of master instead of this tree
    uv run capacity.py instinct2x 24 --first-ref master  master imports and stores, this tree takes over

For every n the mock gets a group of n entities, then a release build pointed at it is run through
what a watch goes through: a first launch (import, refresh, store), relaunches on the stored list
(load, refresh, store - what every later launch does), one toggle, a walk through the list and a
last relaunch.  Per launch it records how many entities were refreshed, whether the group had to
be imported again (nothing was stored), the memory in use and any crash.

One line of JSON per n is printed as it finishes (RESULT ...) and appended to
work/capacity/results.jsonl, and a table is printed at the end.  Everything lands under work/capacity/.  The simulator is restarted for every n, so a crash cannot leak into
the next one.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ciqsim import Sim, MOCK_HTTPS, HERE, WORK, log

OUT = os.path.join(WORK, "capacity")


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def build(device, ref, group="big"):
    """A release build of this tree (ref None) or of a git ref, pointed at the mock.  Release also on
    the full-memory devices: a debug build has a different memory footprint."""
    label = re.sub(r"[^A-Za-z0-9]+", "-", ref) if ref else "tree"
    host = MOCK_HTTPS          # on every device: releases up to 2.3.0 accept nothing but https
    tree = os.path.abspath(os.path.join(HERE, "..", ".."))
    if ref:
        repo = sh("git", "-C", HERE, "rev-parse", "--show-toplevel").stdout.strip()
        if sh("git", "-C", repo, "rev-parse", "-q", "--verify", ref + "^{commit}").returncode:
            ref = "origin/" + ref
        tree = os.path.join(OUT, "tree-" + label)
        shutil.rmtree(tree, ignore_errors=True)
        os.makedirs(tree)
        ar = subprocess.Popen(["git", "-C", repo, "archive", ref, "widget"], stdout=subprocess.PIPE)
        subprocess.run(["tar", "-x", "-C", tree, "--strip-components=1"], stdin=ar.stdout, check=True)
        if ar.wait():
            sys.exit(f"cannot export {ref}")
    src = os.path.join(OUT, f"src-{label}-{device}")
    prg = os.path.join(OUT, f"{label}-{device}.prg")
    r = sh(os.path.join(HERE, "mkvariant.sh"), tree, src, f"host={host}", "accessToken=TESTTOKEN", f"group={group}")
    if r.returncode:
        sys.exit("mkvariant failed:\n" + r.stdout + r.stderr)
    if os.path.exists(prg):
        os.remove(prg)
    r = sh(os.path.join(HERE, "build.sh"), src, device, prg, "release")
    if not os.path.exists(prg):
        sys.exit("build failed:\n" + r.stdout[-3000:])
    m = re.search(r"Foreground:\s*\n\s*Code: (\d+) bytes\s*\n\s*Data: (\d+) bytes", r.stdout)
    static = int(m.group(1)) + int(m.group(2)) if m else None
    log(f"built {label} for {device}: {static} bytes of code and data")
    return prg, label, static


def make_group(mock, n, mixed):
    """group.big with n entities: switches, or - mixed - the mock's own group.all (one entity of
    every supported type) with copies of its members appended until there are n."""
    mock.reset()
    if mixed:
        states = mock._call("/_test/state")
        members = states["group.all"]["attributes"]["entity_id"]
        ids = []
        for k in range(n):
            src = members[k % len(members)]
            if k < len(members):
                ids.append(src)
                continue
            domain, name = src.split(".", 1)
            eid = f"{domain}.{name}_{k // len(members) + 1}"
            attrs = dict(states[src].get("attributes") or {})
            attrs["friendly_name"] = f"{attrs.get('friendly_name', name)} {k // len(members) + 1}"
            mock._call("/_test/set", {"entity_id": eid, "state": states[src]["state"], "attributes": attrs})
            ids.append(eid)
    else:
        ids = [f"switch.room_light_{i:03d}" for i in range(1, n + 1)]
        for i, eid in enumerate(ids):
            mock._call("/_test/set", {"entity_id": eid, "state": "on" if i % 2 else "off",
                                      "attributes": {"friendly_name": f"Room Light {i + 1:03d}"}})
    mock._call("/_test/set", {"entity_id": "group.big", "state": "on",
                              "attributes": {"friendly_name": "Big", "entity_id": ids}})
    return ids


def wait_quiet(mock, since, quiet=7, limit=300, idle_limit=45):
    """Wait until the widget has stopped sending requests.  False when it never sent any."""
    last, quiet_since, t0 = -1, time.time(), time.time()
    while time.time() - t0 < limit:
        cnt = len([e for e in mock.log() if e["ts"] > since])
        if cnt != last:
            last, quiet_since = cnt, time.time()
        elif cnt > 0 and time.time() - quiet_since > quiet:
            return True
        elif cnt == 0 and time.time() - quiet_since > idle_limit:
            return False
        time.sleep(1.0)
    return False


def crash_of(sim, mark):
    text = sim.crashes_since(mark)
    m = re.search(r"Error:\s*(.+)", text)
    return m.group(1).strip() if m else ("yes" if text.strip() else "")


def open_entities(sim):
    """On a device without glances the widget starts on its page of the widget loop ("HassControl"),
    and a tap opens the entity view from there.  Every phase needs that view up: it is the one that
    loads an icon for every redraw, which on a colour display is the largest single allocation."""
    if sim.dev.glance_kb or not re.search(r"hass\s*control", sim.ocr(), re.I):
        return False
    w, h = sim.display_size()
    sim.tap(w // 2, h // 2)
    time.sleep(1.5)
    return True


def launch_phase(sim, mock, prg, fresh, tag):
    """Push and launch a build, wait for its requests to stop, and report what it did."""
    since, mark = time.time(), sim.crash_mark()
    if fresh:
        sim.push(prg)
    else:
        sim.push(prg, fresh_settings=True, fresh_storage=False)
    launched = sim.launch()
    settled = wait_quiet(mock, since)
    time.sleep(4)                      # the deferred finish stores the list after the last response
    open_entities(sim)
    _, img = sim.shot(tag)
    text = sim.ocr(img)
    reqs = [e for e in mock.log() if e["ts"] > since]
    states = [e for e in reqs if e["method"] == "GET" and "/api/states/" in e["path"]]
    refreshed = {e["path"] for e in states if not e["path"].endswith("/group.big")}
    used, total = sim.memory()
    low = re.search(r"only\s+(\d+)\s*of\s*(\d+)", text, re.I)
    return {"phase": tag, "launched": launched, "settled": settled,
            "group_gets": len([e for e in states if e["path"].endswith("/group.big")]),
            "refreshed": len(refreshed), "bad_status": sorted({e.get("status") for e in reqs} - {200}),
            "mem": [used, total], "crash": crash_of(sim, mark),
            "message": ("import cut to %s of %s" % low.groups()) if low
                       else "group too large" if re.search(r"too\s*large", text, re.I) else ""}


def use_phase(sim, mock, n):
    """A toggle on the first entity and a walk through the list, on the build that is running."""
    since, mark = time.time(), sim.crash_mark()
    open_entities(sim)
    sim.select()
    called = mock.wait_request(r"/api/services/", timeout=10, since=since, method="POST") is not None
    time.sleep(4)                      # a lock or cover is refreshed again 2 s later
    for _ in range(min(n, 14)):
        sim.next_page()
        time.sleep(0.3)
    time.sleep(1.5)
    sim.shot("after-walk")
    used, total = sim.memory()
    return {"phase": "use", "toggle_sent": called, "mem": [used, total], "crash": crash_of(sim, mark),
            "running": sim.running()}


def one(device, n, prg, first_prg, label, mixed, relaunches, outdir):
    sim = Sim(device, os.path.join(outdir, f"{label}-{device}-{'mixed' if mixed else 'big'}{n}"))
    mock = sim.mock_https
    make_group(mock, n, mixed)
    res = {"device": device, "build": label, "group": "mixed" if mixed else "switches", "n": n, "phases": []}
    try:
        sim.start()
        res["phases"].append(launch_phase(sim, mock, first_prg or prg, True, "first"))
        for i in range(relaunches):
            res["phases"].append(launch_phase(sim, mock, prg, False, f"relaunch{i + 1}"))
        if not res["phases"][-1]["crash"]:
            res["phases"].append(use_phase(sim, mock, n))
            res["phases"].append(launch_phase(sim, mock, prg, False, "last"))
    finally:
        sim.stop()
    res["verdict"] = verdict(res, n)
    print("RESULT " + json.dumps(res, ensure_ascii=False), flush=True)
    with open(os.path.join(outdir, "results.jsonl"), "a") as f:
        f.write(json.dumps(res, ensure_ascii=False) + "\n")
    return res


def verdict(res, n):
    """complete: every launch refreshed all n from the stored list; anything else names what fell short."""
    notes = []
    for p in res["phases"]:
        if p.get("crash"):
            return f"CRASH in {p['phase']}: {p['crash']}"
    first = res["phases"][0]
    if first.get("message"):
        notes.append(first["message"])
    if first["refreshed"] < n and not first.get("message"):
        notes.append(f"first refresh {first['refreshed']}/{n}")
    later = [p for p in res["phases"][1:] if p["phase"] != "use"]
    if any(p["group_gets"] for p in later):
        notes.append("not stored (imported again)")
    short = [p["refreshed"] for p in later if p["refreshed"] < n]
    if short:
        notes.append(f"relaunch refresh {min(short)}/{n}")
    use = [p for p in res["phases"] if p["phase"] == "use"]
    if use and not use[0]["toggle_sent"]:
        notes.append("toggle not sent")
    return "complete" if not notes else "; ".join(notes)


def table(results):
    lines = ["| device | build | group | n | first | relaunches | free after (kB) | verdict |",
             "|---|---|---|---:|---:|---|---:|---|"]
    for r in results:
        ph = r["phases"]
        later = [p for p in ph[1:] if p["phase"] != "use"]
        mem = [p["mem"] for p in ph if p.get("mem") and p["mem"][0] is not None and not p.get("crash")]
        free = f"{mem[-1][1] - mem[-1][0]:.1f}" if mem else "-"
        lines.append(f"| {r['device']} | {r['build']} | {r['group']} | {r['n']} | {ph[0]['refreshed']} | "
                     f"{' '.join(str(p['refreshed']) for p in later) or '-'} | {free} | {r['verdict']} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device")
    ap.add_argument("n", nargs="+", type=int, help="group sizes to try")
    ap.add_argument("--mixed", action="store_true", help="every supported entity type instead of switches only")
    ap.add_argument("--ref", help="build this git ref instead of the working tree")
    ap.add_argument("--first-ref", help="the first launch uses a build of this git ref (an update on stored data)")
    ap.add_argument("--relaunches", type=int, default=3)
    a = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    print(sh(os.path.join(HERE, "mocks.sh"), "start").stdout, end="")
    prg, label, static = build(a.device, a.ref)
    first_prg = None
    if a.first_ref:
        first_prg, first_label, _ = build(a.device, a.first_ref)
        label = f"{first_label}>{label}"
    results = []
    for n in a.n:
        try:
            results.append(one(a.device, n, prg, first_prg, label, a.mixed, a.relaunches, OUT))
        except Exception as e:                      # a simulator that would not start, mostly
            log(f"n={n}: {e}")
            print("RESULT " + json.dumps({"device": a.device, "build": label, "n": n, "error": str(e)[:200]}), flush=True)
    print()
    print(f"code and data of {label} on {a.device}: {static} bytes")
    print(table(results))
    return 1 if any(r["verdict"].startswith("CRASH") for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
