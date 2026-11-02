#!/usr/bin/env bash
# start|stop|status the private rootful Xwayland display the automated runs use (:5 by default,
# CIQ_DISPLAY).  The harness starts it by itself when it is missing; this is for stopping it, or for
# watching a run: `xwayland-run`-less desktops can view it with e.g. `xeyes -display :5`... or simply
# look at the screenshots in work/results/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
DISP=${CIQ_DISPLAY:-:5}
pid() { ps -eo pid,args | awk -v d="$DISP" '($2 ~ /(^|\/)Xwayland$/) && $3 == d {print $1}'; }
case "${1:-status}" in
  start)
    if [ -z "$(pid)" ]; then
      mkdir -p "$WORK"
      setsid nohup Xwayland "$DISP" -geometry 1400x1000 -noreset > "$WORK/xwayland.log" 2>&1 < /dev/null &
      sleep 1
    fi ;;
  stop)
    for p in $(pid); do kill "$p" && echo "stopped Xwayland $DISP (pid $p)"; done ;;
esac
printf 'Xwayland %s: %s\n' "$DISP" "$(pid | sed 's/^$/not running/')"
