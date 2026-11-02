#!/usr/bin/env bash
# Builds the simulator test variants for the automated run: fullmem devices use the plain-http mock
# (http://127.0.0.1:8123), lowmem devices the TLS mock (https://127.0.0.1:8124).
set -u
S=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-/home/gerhard/git_clones/hasscontrol/widget}
OUT="$S/variants2"; mkdir -p "$OUT"
declare -A V
V[base]=""
V[lockyn]="lockConfirmation=1"
V[lockpin]="lockConfirmation=2 lockPin=1234"
V[lockpin-bad]="lockConfirmation=2 lockPin=12a"
V[wifi]="wifiLteExecution=true"
V[wifi-lockyn]="wifiLteExecution=true lockConfirmation=1"
V[wifi-lockpin]="wifiLteExecution=true lockConfirmation=2 lockPin=1234"
V[wifi-close]="wifiLteExecution=true closeAfterAction=true"
V[closeauto]="closeAfterAction=true autoCloseSeconds=60 useListView=true"
V[refresh]="refresh=true useListView=true"
V[http-bad]="host=http://localhost.example.com"
V[http-userinfo]="host=http://localhost:8123@evil.example.com"
V[http-upper]="host=http://LOCALHOST:8123"
V[http-localhost]="host=http://localhost:8123"
V[battery]="report_battery_id=sim_watch"
V[nologin]="accessToken="
FULL="fenix7x venusq2 edge1040 fr255"
LOW="instinct2x vivoactive3"
{
for name in "${!V[@]}"; do
  read -r -a extra <<< "${V[$name]}"
  # fullmem: plain http (loopback feature), debug builds
  "$S/scripts/mkvariant.sh" "$SRC" "$OUT/tw-$name" host=http://127.0.0.1:8123 accessToken=TESTTOKEN group=garmin "${extra[@]}" > /dev/null
  for dev in $FULL; do
    out="$OUT/$name-$dev.prg"; log=$("$S/scripts/build.sh" "$OUT/tw-$name" "$dev" "$out" debug)
    if [ -f "$out" ]; then echo "OK   $name $dev debug"; else echo "FAIL $name $dev debug"; echo "$log" | grep -i error | head -3; fi
  done
  # lowmem: https to the TLS mock, release builds (the http-* variants keep their host: they test the rejection)
  "$S/scripts/mkvariant.sh" "$SRC" "$OUT/tl-$name" host=https://127.0.0.1:8124 accessToken=TESTTOKEN group=garmin "${extra[@]}" > /dev/null
  for dev in $LOW; do
    out="$OUT/$name-$dev.prg"; log=$("$S/scripts/build.sh" "$OUT/tl-$name" "$dev" "$out" release)
    if [ -f "$out" ]; then echo "OK   $name $dev release"; else echo "FAIL $name $dev release"; echo "$log" | grep -i error | head -3; fi
  done
done
# plain-http base for the lowmem devices (expected: "Check settings, invalid url")
"$S/scripts/mkvariant.sh" "$SRC" "$OUT/tw-base" host=http://127.0.0.1:8123 accessToken=TESTTOKEN group=garmin > /dev/null
for dev in $LOW; do
  out="$OUT/http-base-$dev.prg"; log=$("$S/scripts/build.sh" "$OUT/tw-base" "$dev" "$out" release)
  if [ -f "$out" ]; then echo "OK   http-base $dev release"; else echo "FAIL http-base $dev release"; fi
done
} > "$OUT/BUILD-RESULTS.txt" 2>&1
echo "done: $(grep -c '^OK' "$OUT/BUILD-RESULTS.txt") ok, $(grep -c '^FAIL' "$OUT/BUILD-RESULTS.txt") failed"
