#!/usr/bin/env bash
# Re-run named scenarios one per process with a clean slate before each (as retry-failures.sh), keeping
# run.py's full output in results/<name>/run.log.  A scenario that runs first in its process is spared
# run.py's between-scenario Settings-menu click that puts the phone back on.
S=$(cd "$(dirname "$0")/.." && pwd)
for name in "$@"; do
  "$S/scripts/cleanup.sh" > /dev/null 2>&1
  sleep 3
  rm -rf "$S/results/$name"; mkdir -p "$S/results/$name"
  timeout 900 "$S/venv/bin/python" "$S/harness/run.py" "$name" > "$S/results/$name/run.log" 2>&1
  echo "$name: $(grep -m1 -o 'Result: [^*]*' "$S/results/$name/REPORT.md" 2>/dev/null || echo 'no report')"
done
"$S/scripts/cleanup.sh" > /dev/null 2>&1
echo "===== retries done ====="
