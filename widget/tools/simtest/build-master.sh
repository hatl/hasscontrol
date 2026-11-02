#!/usr/bin/env bash
# Builds the widget as it is on master (plain, no setting overrides) for the settings-upgrade
# scenario (f7_stale_settings), which runs it first so the simulator stores its settings, then the
# current build on top of them.
# usage: build-master.sh [device ...]      -> work/out/master-<device>-debug.prg
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
SRC="$WORK/master-src"
rm -rf "$SRC"; mkdir -p "$SRC" "$WORK/out"
git -C "$REPO" archive master widget | tar -x -C "$SRC" --strip-components=1
for dev in ${*:-fenix7x}; do
  out="$WORK/out/master-$dev-debug.prg"; rm -f "$out"
  log=$("$HERE/build.sh" "$SRC" "$dev" "$out" debug)
  if [ -f "$out" ]; then echo "OK   master $dev ($(git -C "$REPO" rev-parse --short master))"; else echo "FAIL master $dev"; echo "$log" | grep -iE 'error' | head -5; fi
done
