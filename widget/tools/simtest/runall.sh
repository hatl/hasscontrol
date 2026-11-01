#!/usr/bin/env bash
# Run the scenarios one device at a time, each in its own process with a clean slate in between.
# The simulator gets unreliable when it is restarted many times inside a single long-lived process.
S=$(cd "$(dirname "$0")/.." && pwd)
PY="$S/venv/bin/python"
for dev in fenix7x venusq2 edge1040 fr255 instinct2x vivoactive3; do
  echo "===== $dev ====="
  "$S/scripts/cleanup.sh" > /dev/null 2>&1
  sleep 3
  timeout 2400 "$PY" "$S/harness/run.py" "$dev" 2>&1 | grep -E 'report .*(PASS|FAIL)|ERROR in' | sed 's|.*/results/||'
done
"$S/scripts/cleanup.sh" > /dev/null 2>&1
echo "===== done ====="
