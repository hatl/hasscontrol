#!/usr/bin/env bash
# Builds the widget as it is on master (or on another ref), for the scenarios that run an older build
# first and the current one on top of what it left behind:
#   work/out/master-<device>-debug.prg    plain, no setting overrides - f7_stale_settings runs it so
#                                         the simulator stores its settings
#   work/variants2/master-<device>.prg    pointed at the mock like the other variants (fullmem: debug,
#                                         http://127.0.0.1:8123; lowmem: release, https://127.0.0.1:8124)
#                                         - i2_phone_lost and the storage upgrade scenarios
# usage: [REF=master] [NAME=master] [FULL="fenix7x"] [LOW="instinct2x"] build-master.sh [device ...]
#        (the devices are those of the plain build, fenix7x by default)
#        REF=v2.1.0 NAME=v210 build-master.sh     builds that release as v210-<device>.prg
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
REF=${REF:-master}
NAME=${NAME:-master}
FULL=${FULL:-fenix7x}
LOW=${LOW:-instinct2x}
OUT=${OUT:-$WORK/variants2}
SRC="$WORK/$NAME-src"
# A clone that has only checked out a feature branch knows master as origin/master.
git -C "$REPO" rev-parse -q --verify "$REF^{commit}" > /dev/null || REF="origin/$REF"
rm -rf "$SRC"; mkdir -p "$SRC" "$WORK/out" "$OUT"
git -C "$REPO" archive "$REF" widget | tar -x -C "$SRC" --strip-components=1 || { echo "FAIL $NAME: cannot export $REF"; exit 1; }
SHORT=$(git -C "$REPO" rev-parse --short "$REF")
FAILED=0

# build <variant-dir> <device> <out.prg> <debug|release> <label>
build() {
  local log
  rm -f "$3"
  log=$("$HERE/build.sh" "$1" "$2" "$3" "$4")
  if [ -f "$3" ]; then echo "OK   $5 $2 $4 ($SHORT)"; else echo "FAIL $5 $2 $4"; echo "$log" | grep -iE 'error' | head -5; FAILED=1; fi
}

for dev in ${*:-fenix7x}; do
  build "$SRC" "$dev" "$WORK/out/$NAME-$dev-debug.prg" debug "$NAME (plain)"
done

COMMON="accessToken=TESTTOKEN group=garmin"
if [ -n "$FULL" ]; then
  # shellcheck disable=SC2086
  "$HERE/mkvariant.sh" "$SRC" "$OUT/tw-$NAME" host=http://127.0.0.1:8123 $COMMON > /dev/null || { echo "FAIL mkvariant tw-$NAME"; FAILED=1; }
  for dev in $FULL; do build "$OUT/tw-$NAME" "$dev" "$OUT/$NAME-$dev.prg" debug "$NAME"; done
fi
if [ -n "$LOW" ]; then
  # shellcheck disable=SC2086
  "$HERE/mkvariant.sh" "$SRC" "$OUT/tl-$NAME" host=https://127.0.0.1:8124 $COMMON > /dev/null || { echo "FAIL mkvariant tl-$NAME"; FAILED=1; }
  for dev in $LOW; do build "$OUT/tl-$NAME" "$dev" "$OUT/$NAME-$dev.prg" release "$NAME"; done
fi
exit $FAILED
