#!/usr/bin/env bash
# Run only the "date and time" scenarios, one device per process with a clean slate in between (as
# runall.sh does - the simulator gets unreliable when one process restarts it many times).
# run.py selects by device OR name OR feature, so the scenario names are taken from the registry.
# usage: rundt.sh [device ...]        summaries: results/SUMMARY-dt-<device>.md, full logs: results/rundt-<device>.log
S=$(cd "$(dirname "$0")/.." && pwd)
PY="$S/venv/bin/python"
DEVICES=${*:-fenix7x venusq2 edge1040 fr255 instinct2x vivoactive3}
for dev in $DEVICES; do
  names=$(cd "$S/harness" && "$PY" -c "import scenarios as s; print(' '.join(x['name'] for x in s.REGISTRY if x['feature'] == 'date and time' and x['device'] == '$dev'))")
  [ -z "$names" ] && { echo "===== $dev: no date/time scenarios ====="; continue; }
  echo "===== $dev: $names ====="
  "$S/scripts/cleanup.sh" > /dev/null 2>&1
  sleep 3
  # shellcheck disable=SC2086
  timeout 2400 "$PY" "$S/harness/run.py" $names > "$S/results/rundt-$dev.log" 2>&1
  grep -E 'report .*(PASS|FAIL)|ERROR in' "$S/results/rundt-$dev.log" | sed 's|.*/results/||'
  cp "$S/results/SUMMARY.md" "$S/results/SUMMARY-dt-$dev.md" 2>/dev/null
done
"$S/scripts/cleanup.sh" > /dev/null 2>&1
echo "===== done ====="
