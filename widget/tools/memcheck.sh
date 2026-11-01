#!/usr/bin/env bash
# Regression guard for the 64 KB widget devices (see monkey.jungle).
#
# code+data is resident for the whole app run; whatever is left of the device's
# widget memory limit is all the heap the app has for entities, HTTP responses
# and bitmaps. v1.9.1 ran with ~30 KB of heap; v2.0.3 had shrunk it to ~11.8 KB
# and OOMed on Instinct 2X. Keep HEAP_LEFT comfortably above ~25000.
#
#   usage: tools/memcheck.sh [widget-dir]
set -u
SDK=${CIQ_SDK:-$(cat "$HOME/.Garmin/ConnectIQ/current-sdk.cfg")}
KEY=${CIQ_KEY:-$HOME/Programme/connectiq-sdk-manager/developer_key}
DIR=$(cd "${1:-$(dirname "$0")/..}" && pwd)
LIMIT=65536
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

printf "%-20s %8s %8s %8s %10s\n" DEVICE DATA CODE STATIC HEAP_LEFT
for d in descentg1 enduro fenix5 fenix5s fenix6 fenix6s fenixchronos fr245 fr55 \
         fr645 fr935 instinct2 instinct2s instinct2x instinctcrossover venusq vivoactive3; do
  ( cd "$DIR" && "$SDK/bin/monkeyc" -f monkey.jungle -o "$OUT/$d.prg" -y "$KEY" \
      -d "$d" --build-stats 1 -r -O2 2>&1 ) |
  awk -v D="$d" -v L="$LIMIT" '
    # SDK <= 8.x prints "Data:" / "Code:" headers with per-section lines below;
    # SDK 9.x prints "Foreground:" / "Glance:" headers with "Code: N" / "Data: N"
    # lines below. Only the foreground figures count against the widget budget.
    /^[[:space:]]*Data:[[:space:]]*$/ {mode="data"; next}
    /^[[:space:]]*Code:[[:space:]]*$/ {mode="code"; next}
    /^[[:space:]]*Foreground:[[:space:]]*$/ {sec="fg"; next}
    /^[[:space:]]*(Glance|Background|Extended Code):/ {sec="other"; next}
    /Foreground:[[:space:]]*[0-9]+/ {if (mode=="data") dd=$2; else if (mode=="code") cc=$2}
    sec=="fg" && /Code:[[:space:]]*[0-9]+/ {cc=$2}
    sec=="fg" && /Data:[[:space:]]*[0-9]+/ {dd=$2}
    /ERROR/ {e=$0}
    END { if (e != "") printf "%-20s %s\n", D, e
          else printf "%-20s %8d %8d %8d %10d\n", D, dd, cc, dd+cc, L-(dd+cc) }'
done
