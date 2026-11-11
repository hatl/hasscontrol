#!/usr/bin/env python3
"""Run the simulator scenarios and write a summary.

    run.py                      every scenario, device by device
    run.py fenix7x instinct2x   only those devices
    run.py f7_lock_pin_ok       one scenario by name

Results land in work/results/<scenario>/ (REPORT.md, screenshots, app log) and a summary in
work/results/SUMMARY.md.  Run it with `uv run run.py ...` from this folder (see README.md).
"""
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ciqsim import Sim, Report, S, log
import scenarios
from scenarios import REGISTRY


def wanted(args):
    if not args:
        return REGISTRY
    sel = []
    for s in REGISTRY:
        if s["device"] in args or s["name"] in args or s["feature"] in args:
            sel.append(s)
    return sel


def main():
    args = sys.argv[1:]
    todo = wanted(args)
    if not todo:
        print("nothing matched", args)
        print("devices:", sorted({s['device'] for s in REGISTRY}))
        print("scenarios:", [s["name"] for s in REGISTRY])
        return 2

    by_device = {}
    for s in todo:
        by_device.setdefault(s["device"], []).append(s)

    results = []
    started = time.time()
    for device, group in by_device.items():
        log(f"===== {device}: {len(group)} scenarios =====")
        sim = None
        for sc in group:
            name = sc["name"]
            t0 = time.time()
            try:
                if sim is None:
                    sim = Sim(device, f"{S}/results/{name}")
                    sim.start()
                else:
                    sim.log_dir = f"{S}/results/{name}"
                    os.makedirs(sim.log_dir, exist_ok=True)
                    sim.shot_count = 0
                    # Scenarios must not inherit the connection state of the one before: a Wi-Fi
                    # scenario leaves the phone disconnected, and the next one then silently fails
                    # to fetch anything.  Only when it is not known to be connected already: every
                    # trip through the simulator's Settings menu risks its GTK crash (see Sim.ble_state).
                    if sim.ble_state != "Connected":
                        sim.set_ble("Connected")
                rep = Report(name, sim)
                rep.lines.insert(1, f"_{device} · {sc['feature']}_")
                rep.lines.insert(2, "")
                doc = (sc["fn"].__doc__ or "").strip()
                if doc:
                    rep.lines.insert(3, doc)
                    rep.lines.insert(4, "")
                sc["fn"](sim, rep)
                for note in sim.notes:
                    rep.lines.append(f"- note: {note}")
                sim.notes = []
                rep.finish()
                results.append({"name": name, "device": device, "feature": sc["feature"],
                                "checks": rep.checks, "failures": rep.failures,
                                "secs": round(time.time() - t0), "error": None,
                                "dir": rep.dir})
            except Exception as e:
                tb = traceback.format_exc()
                log(f"ERROR in {name}: {e}")
                d = f"{S}/results/{name}"
                os.makedirs(d, exist_ok=True)
                open(d + "/ERROR.txt", "w").write(tb)
                try:
                    if sim:
                        sim.shot("error-state", full=True)
                except Exception:
                    pass
                results.append({"name": name, "device": device, "feature": sc["feature"],
                                "checks": 0, "failures": 1, "secs": round(time.time() - t0),
                                "error": str(e)[:200], "dir": d})
                if sim:
                    try:
                        sim.stop()
                    except Exception:
                        pass
                    sim = None
        if sim:
            sim.stop()

    lines = ["# Simulator run", "",
             f"{len(results)} scenarios, {round(time.time() - started)} s", ""]
    lines.append("| scenario | device | feature | checks | failed | s |")
    lines.append("|---|---|---|---:|---:|---:|")
    for r in results:
        status = r["error"] or ("" if r["failures"] == 0 else f"{r['failures']} failed")
        lines.append(f"| [{r['name']}]({r['name']}/REPORT.md) | {r['device']} | {r['feature']} | "
                     f"{r['checks']} | {status or '-'} | {r['secs']} |")
    failed = [r for r in results if r["failures"]]
    lines += ["", f"**{len(results) - len(failed)} of {len(results)} scenarios passed.**", ""]
    if failed:
        lines.append("Failing: " + ", ".join(r["name"] for r in failed))
    # CIQ_SUMMARY: jobs that run side by side (runall.sh -j) each write a summary of their own
    path = f"{S}/results/{os.environ.get('CIQ_SUMMARY', 'SUMMARY.md')}"
    open(path, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines[-6:]))
    log("summary: " + path)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
