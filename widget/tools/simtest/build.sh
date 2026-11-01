#!/usr/bin/env bash
# usage: build.sh <widget-dir> <device> <out.prg> [release] [extra monkeyc args...]
# Builds with the SDK from ~/.Garmin/ConnectIQ/current-sdk.cfg and prints build stats.
set -u
DIR="$1"; DEV="$2"; OUT="$3"; MODE="${4:-debug}"; shift 4 || shift $#
SDK=${CIQ_SDK:-$(cat "$HOME/.Garmin/ConnectIQ/current-sdk.cfg")}
KEY=${CIQ_KEY:-$HOME/Programme/connectiq-sdk-manager/developer_key}
EXTRA=()
if [ "$MODE" = "release" ]; then EXTRA=(-r -O2); fi
cd "$DIR" && java -jar "$SDK/bin/monkeybrains.jar" -o "$OUT" -f monkey.jungle -y "$KEY" -d "$DEV" -w -l 0 --build-stats 1 "${EXTRA[@]}" "$@" 2>&1
