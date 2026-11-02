#!/usr/bin/env bash
# Builds the date/time test variants (group.datetime of the mock) from the implementer's worktree,
# the way build-variants2.sh builds the others:
#   dt-<device>.prg      fullmem devices: debug, plain http to the mock on 8123
#                        lowmem devices:  release, https to the TLS mock on 8124
#   dtwifi-fenix7x.prg   debug, https to 8124 (Wi-Fi/LTE refuses plain http), wifiLteExecution=true
# usage: [SRC=<widget dir>] [OUT=<dir>] build-dt-variants.sh      results: <OUT>/BUILD-DT-RESULTS.txt
set -u
S=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-$S/wt-dt/widget}
OUT=${OUT:-$S/variants2}; mkdir -p "$OUT"
FULL="fenix7x venusq2 edge1040 fr255"
LOW="instinct2x vivoactive3"
COMMON="accessToken=TESTTOKEN group=datetime"

# build <variant-dir> <name> <device> <debug|release>
build() {
  local dir="$1" name="$2" dev="$3" mode="$4" out log
  out="$OUT/$name-$dev.prg"
  rm -f "$out"          # a stale .prg from an earlier build must not pass for a fresh one
  log=$("$S/scripts/build.sh" "$dir" "$dev" "$out" "$mode")
  if [ -f "$out" ]; then echo "OK   $name $dev $mode"; else echo "FAIL $name $dev $mode"; echo "$log" | grep -iE 'error|warning: .*not' | head -5; fi
}

{
echo "source: $SRC ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo 'no git'), $(git -C "$SRC" status --porcelain 2>/dev/null | wc -l) uncommitted paths)"
# shellcheck disable=SC2086
"$S/scripts/mkvariant.sh" "$SRC" "$OUT/tw-dt" host=http://127.0.0.1:8123 $COMMON > /dev/null || echo "FAIL mkvariant tw-dt"
for dev in $FULL; do build "$OUT/tw-dt" dt "$dev" debug; done
# shellcheck disable=SC2086
"$S/scripts/mkvariant.sh" "$SRC" "$OUT/tl-dt" host=https://127.0.0.1:8124 $COMMON > /dev/null || echo "FAIL mkvariant tl-dt"
for dev in $LOW; do build "$OUT/tl-dt" dt "$dev" release; done
# shellcheck disable=SC2086
"$S/scripts/mkvariant.sh" "$SRC" "$OUT/tw-dtwifi" host=https://127.0.0.1:8124 $COMMON wifiLteExecution=true > /dev/null || echo "FAIL mkvariant tw-dtwifi"
build "$OUT/tw-dtwifi" dtwifi fenix7x debug
} > "$OUT/BUILD-DT-RESULTS.txt" 2>&1
echo "done: $(grep -c '^OK' "$OUT/BUILD-DT-RESULTS.txt") ok, $(grep -c '^FAIL' "$OUT/BUILD-DT-RESULTS.txt") failed (see $OUT/BUILD-DT-RESULTS.txt)"
