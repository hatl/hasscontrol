#!/usr/bin/env python3
"""Walk the widget on one device and dump what every step looks like.

Not a test: it produces screenshots, OCR text, app log and mock traffic for each step, so the
scenario assertions can be written against the real screens.

usage: explore.py <device> <variant> [steps...]
       steps: down up enter esc menu tap:X,Y swipe:X1,Y1,X2,Y2 wait:SEC shot:NAME
"""
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ciqsim import Sim, Mock, MOCK_HTTP, MOCK_HTTPS, S, VARIANTS, LOWMEM, ensure_mocks, log


def main():
    device = sys.argv[1]
    variant = sys.argv[2]
    steps = sys.argv[3:] or ["shot:start"]
    sim = Sim(device, f"{S}/results/explore-{device}-{variant}")
    ensure_mocks()
    mock = Mock(MOCK_HTTPS if device in LOWMEM else MOCK_HTTP)
    mock.reset()
    sim.start()
    prg = f"{VARIANTS}/{variant}-{device}.prg"
    sim.push(prg)
    launched = sim.launch()
    out = [f"# explore {device} / {variant}", "", f"launched: {launched}", ""]

    def record(label):
        time.sleep(1.0)
        path, img = sim.shot(label)
        txt = sim.ocr(img)
        used, total = sim.memory()
        out.append(f"## {label}")
        out.append(f"- memory {used}/{total} kB")
        out.append(f"- ocr: `{txt!r}`")
        out.append(f"- ![{label}]({path.rsplit('/', 1)[1]})")
        reqs = mock.log()
        out.append(f"- mock so far: {[(e['method'], e['path']) for e in reqs][-4:]} (total {len(reqs)})")
        out.append("")
        print(f"--- {label}: mem {used}/{total} ocr {txt!r}")

    record("after-launch")
    for st in steps:
        if st.startswith("wait:"):
            time.sleep(float(st[5:]))
            record("wait-" + st[5:])
            continue
        if st.startswith("shot:"):
            record(st[5:])
            continue
        if st.startswith("tap:"):
            x, y = map(int, st[4:].split(","))
            sim.tap(x, y)
            record(f"tap-{x}-{y}")
            continue
        if st.startswith("swipe:"):
            a, b, c, d = map(int, st[6:].split(","))
            sim.swipe(a, b, c, d)
            record(f"swipe-{a}-{b}")
            continue
        sim.key(st)
        record("key-" + st)

    out.append("## app log")
    out.append("```")
    out.append("\n".join(l for l in sim.applog().splitlines() if not l.startswith("MEM "))[:4000])
    out.append("```")
    out.append("## mock requests")
    out.append("```")
    for e in mock.log():
        out.append(f"{e['method']} {e['path']} auth={e['auth']} {e['body']}")
    out.append("```")
    path = sim.log_dir + "/EXPLORE.md"
    open(path, "w").write("\n".join(out) + "\n")
    log("wrote " + path)
    sim.stop()


if __name__ == "__main__":
    main()
