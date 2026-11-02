#!/usr/bin/env bash
# Run only the "date and time" scenarios, one device per process with a clean slate in between (as
# runall.sh does - the simulator gets unreliable when one process restarts it many times).
# run.py selects by device OR name OR feature, so the scenario names are taken from the registry.
# usage: rundt.sh [device ...]        summaries: work/results/SUMMARY-dt-<device>.md, full logs: work/results/rundt-<device>.log
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
DEVICES=${*:-fenix7x venusq2 edge1040 fr255 instinct2x vivoactive3}
mkdir -p "$WORK/results"
for dev in $DEVICES; do
  names=$(uv run --project "$HERE" python -c "import sys; sys.path.insert(0, '$HERE'); import scenarios as s; print(' '.join(x['name'] for x in s.REGISTRY if x['feature'] == 'date and time' and x['device'] == '$dev'))")
  [ -z "$names" ] && { echo "===== $dev: no date/time scenarios ====="; continue; }
  echo "===== $dev: $names ====="
  "$HERE/cleanup.sh" > /dev/null 2>&1
  sleep 3
  # shellcheck disable=SC2086
  timeout 2400 uv run --project "$HERE" "$HERE/run.py" $names > "$WORK/results/rundt-$dev.log" 2>&1
  grep -E 'report .*(PASS|FAIL)|ERROR in' "$WORK/results/rundt-$dev.log" | sed 's|.*/results/||'
  cp "$WORK/results/SUMMARY.md" "$WORK/results/SUMMARY-dt-$dev.md" 2>/dev/null
done
"$HERE/cleanup.sh" > /dev/null 2>&1
echo "===== done ====="
