#!/usr/bin/env bash
# Re-run named scenarios one per process, with a clean slate before each.
S=$(cd "$(dirname "$0")/.." && pwd)
for name in "$@"; do
  "$S/scripts/cleanup.sh" > /dev/null 2>&1
  sleep 3
  mkdir -p "$S/results/$name"
  # the full output stays next to the report, for triage
  timeout 900 "$S/venv/bin/python" "$S/harness/run.py" "$name" > "$S/results/$name/run.log" 2>&1
  grep -E 'report .*(PASS|FAIL)|ERROR in' "$S/results/$name/run.log" | sed 's|.*/results/||'
done
"$S/scripts/cleanup.sh" > /dev/null 2>&1
echo "===== retries done ====="
