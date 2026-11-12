#!/usr/bin/env bash
# Every build the automated run needs, from this tree and from release 2.3.0: the settings variants,
# the date/time variants and the builds of the older release.  Takes a quarter of an hour.
# usage: build-all.sh          then: runall.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
OUT=${OUT:-$WORK/variants2}
"$HERE/build-variants2.sh"
"$HERE/build-dt-variants.sh"
"$HERE/build-master.sh" | tee "$OUT/BUILD-MASTER-RESULTS.txt"
FAILS=$(cat "$OUT/BUILD-RESULTS.txt" "$OUT/BUILD-DT-RESULTS.txt" "$OUT/BUILD-MASTER-RESULTS.txt" 2>/dev/null | grep -c '^FAIL')
if [ "$FAILS" -gt 0 ]; then
  echo "===== $FAILS builds failed ====="
  cat "$OUT/BUILD-RESULTS.txt" "$OUT/BUILD-DT-RESULTS.txt" "$OUT/BUILD-MASTER-RESULTS.txt" | grep -A3 '^FAIL'
  exit 1
fi
echo "===== all builds ok ====="
