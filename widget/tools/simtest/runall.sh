#!/usr/bin/env bash
# Run the scenarios one device at a time, each in its own process with a clean slate in between.
# The simulator gets unreliable when it is restarted many times inside a single long-lived process.
# usage: runall.sh [device ...]          summaries: work/results/SUMMARY-<device>.md
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
DEVICES=${*:-fenix7x venusq2 edge1040 fr255 instinct2x vivoactive3}
mkdir -p "$WORK/results"
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
