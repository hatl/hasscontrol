#!/usr/bin/env bash
# Re-run named scenarios one per process, with a clean slate before each.
S=$(cd "$(dirname "$0")/.." && pwd)
for name in "$@"; do
  "$S/scripts/cleanup.sh" > /dev/null 2>&1
  sleep 3
  timeout 900 "$S/venv/bin/python" "$S/harness/run.py" "$name" 2>&1 | grep -E 'report .*(PASS|FAIL)|ERROR in' | sed 's|.*/results/||'
done
"$S/scripts/cleanup.sh" > /dev/null 2>&1
echo "===== retries done ====="
