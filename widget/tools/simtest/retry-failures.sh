#!/usr/bin/env bash
# Re-run named scenarios one per process, with a clean slate before each.  run.py's full output
# stays next to the report (work/results/<name>/run.log) for triage.  A scenario that runs first in
# its process is spared run.py's between-scenario Settings-menu click that puts the phone back on.
# usage: retry-failures.sh <scenario> [scenario ...]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
for name in "$@"; do
  "$HERE/cleanup.sh" > /dev/null 2>&1
  sleep 3
  rm -rf "$WORK/results/$name"; mkdir -p "$WORK/results/$name"
  timeout 900 uv run --project "$HERE" "$HERE/run.py" "$name" > "$WORK/results/$name/run.log" 2>&1
  echo "$name: $(grep -m1 -o 'Result: [^*]*' "$WORK/results/$name/REPORT.md" 2>/dev/null || echo 'no report')"
done
"$HERE/cleanup.sh" > /dev/null 2>&1
echo "===== retries done ====="
