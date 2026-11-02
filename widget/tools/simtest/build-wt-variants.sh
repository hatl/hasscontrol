#!/usr/bin/env bash
# Builds the older scenarios' variants (base, lockyn, closeauto, wifi) from a given source tree into a
# directory of their own, as build-variants2.sh does for the main tree - so a run can use them through
# CIQ_VARIANTS=<OUT> without the main tree's builds of the same names ever being picked up.
#   fullmem (fenix7x by default): debug, http://127.0.0.1:8123; wifi: https://127.0.0.1:8124
#   lowmem (instinct2x by default): release, https://127.0.0.1:8124
# usage: SRC=<widget dir> OUT=<dir> [FULL="fenix7x"] [LOW="instinct2x"] build-wt-variants.sh [variant ...]
# Results are appended to <OUT>/BUILD-WT-RESULTS.txt, so several invocations into one OUT add up.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
SRC=${SRC:?set SRC to the widget directory to build from}
OUT=${OUT:?set OUT to the directory to build into}; mkdir -p "$OUT"
FULL=${FULL:-fenix7x}
LOW=${LOW:-instinct2x}
declare -A V
V[base]=""
V[lockyn]="lockConfirmation=1"
V[closeauto]="closeAfterAction=true autoCloseSeconds=60 useListView=true"
V[wifi]="wifiLteExecution=true"
WANT=${*:-base lockyn closeauto wifi}

build() {   # build <variant-dir> <name> <device> <debug|release>
  local out="$OUT/$2-$3.prg" log
  rm -f "$out"
  log=$("$HERE/build.sh" "$1" "$3" "$out" "$4")
  if [ -f "$out" ]; then echo "OK   $2 $3 $4"; else echo "FAIL $2 $3 $4"; echo "$log" | grep -iE 'error' | head -5; fi
}

{
echo "source: $SRC ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo 'no git'), $(git -C "$SRC" status --porcelain 2>/dev/null | wc -l) uncommitted paths)"
for name in $WANT; do
  read -r -a extra <<< "${V[$name]}"
  host=http://127.0.0.1:8123
  [ "$name" = wifi ] && host=https://127.0.0.1:8124      # Wi-Fi/LTE refuses plain http
  "$HERE/mkvariant.sh" "$SRC" "$OUT/tw-$name" host=$host accessToken=TESTTOKEN group=garmin "${extra[@]}" > /dev/null || echo "FAIL mkvariant tw-$name"
  for dev in $FULL; do build "$OUT/tw-$name" "$name" "$dev" debug; done
  if [ "$name" = base ]; then
    "$HERE/mkvariant.sh" "$SRC" "$OUT/tl-$name" host=https://127.0.0.1:8124 accessToken=TESTTOKEN group=garmin > /dev/null || echo "FAIL mkvariant tl-$name"
    for dev in $LOW; do build "$OUT/tl-$name" "$name" "$dev" release; done
  fi
done
} > "$OUT/.build-wt-last.txt" 2>&1
cat "$OUT/.build-wt-last.txt" >> "$OUT/BUILD-WT-RESULTS.txt"      # one file for every invocation into OUT
echo "done: $(grep -c '^OK' "$OUT/.build-wt-last.txt") ok, $(grep -c '^FAIL' "$OUT/.build-wt-last.txt") failed (see $OUT/BUILD-WT-RESULTS.txt)"
