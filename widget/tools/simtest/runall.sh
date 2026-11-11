#!/usr/bin/env bash
# Run the scenarios, each device in a process of its own with a clean slate in between.  The
# simulator gets unreliable when it is restarted many times inside a single long-lived process.
#
# usage: runall.sh [-j N] [device ...]      summaries: work/results/SUMMARY-<device>.md
#
# -j N runs N jobs side by side, each in a sandbox of its own (sandbox.sh): the full run takes
# about a quarter of the time with -j 6.  A device with many scenarios is split into several jobs
# (CHUNK scenarios each, 8 by default); summaries are then work/results/SUMMARY-<device>-<n>.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
JOBS=1
if [ "${1:-}" = "-j" ]; then JOBS=$2; shift 2; fi
DEVICES=${*:-fenix7x venusq2 edge1040 fr255 instinct2x vivoactive3}
mkdir -p "$WORK/results"

if [ "$JOBS" -le 1 ]; then
  for dev in $DEVICES; do
    echo "===== $dev ====="
    "$HERE/cleanup.sh" > /dev/null 2>&1
    sleep 3
    timeout 2400 uv run --project "$HERE" "$HERE/run.py" "$dev" > "$WORK/results/runall-$dev.log" 2>&1
    grep -E 'report .*(PASS|FAIL)|ERROR in' "$WORK/results/runall-$dev.log" | sed 's|.*/results/||'
    cp "$WORK/results/SUMMARY.md" "$WORK/results/SUMMARY-$dev.md" 2>/dev/null
  done
  "$HERE/cleanup.sh" > /dev/null 2>&1
  echo "===== done ====="
  exit 0
fi

# ---- side by side
uv sync --project "$HERE" -q                       # the jobs have no network: the environment first
"$HERE/mocks.sh" start > /dev/null; "$HERE/mocks.sh" stop > /dev/null    # the TLS certificate, once
# one line per job: <label> <scenario> [<scenario> ...]
"$HERE/.venv/bin/python" - "$HERE" "${CHUNK:-8}" $DEVICES > "$WORK/results/jobs.txt" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import scenarios
size = int(sys.argv[2])
for dev in sys.argv[3:]:
    names = [s["name"] for s in scenarios.REGISTRY if s["device"] == dev]
    chunks = [names[i:i + size] for i in range(0, len(names), size)]
    for n, chunk in enumerate(chunks, 1):
        print(dev if len(chunks) == 1 else f"{dev}-{n}", *chunk)
PY
job() {
  local label=$1; shift
  CIQ_SUMMARY="SUMMARY-$label.md" timeout 2400 "$HERE/sandbox.sh" "$HERE/.venv/bin/python" "$HERE/run.py" "$@" \
    > "$WORK/results/runall-$label.log" 2>&1
  echo "===== $label ====="
  grep -E 'report .*(PASS|FAIL)|ERROR in' "$WORK/results/runall-$label.log" | sed 's|.*/results/||'
}
export -f job; export HERE WORK
# shellcheck disable=SC2016
xargs -P "$JOBS" -L 1 bash -c 'job $0 "$@"' < "$WORK/results/jobs.txt"
# Six simulators at once keep the machine busy, and now and then a tap or a key press of a scenario
# is lost that way.  Whatever failed gets one more run, on its own.
PASSED=$(grep -h 'report .*PASS' "$WORK"/results/runall-*.log | wc -l)
FAILED=$( { grep -h 'report .*FAIL' "$WORK"/results/runall-*.log | sed 's|.*/results/\([^/]*\)/REPORT.md.*|\1|'
            grep -h 'ERROR in' "$WORK"/results/runall-*.log | sed 's|.*ERROR in \([^:]*\):.*|\1|'; } | sort -u)
STILL=0
for name in $FAILED; do
  CIQ_SUMMARY="SUMMARY-retry.md" timeout 900 "$HERE/sandbox.sh" "$HERE/.venv/bin/python" "$HERE/run.py" "$name" \
    > "$WORK/results/retry-$name.log" 2>&1
  if grep -q 'report .*PASS' "$WORK/results/retry-$name.log"; then
    echo "$name: PASS on its own (failed in the parallel run)"; PASSED=$((PASSED + 1))
  else
    echo "$name: FAIL again, see $WORK/results/$name/REPORT.md"; STILL=$((STILL + 1))
  fi
done
echo "===== done: $PASSED passed, $STILL failed ====="
[ "$STILL" -eq 0 ]
