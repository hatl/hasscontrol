#!/usr/bin/env bash
# start|stop|status the private X display the automated runs use (:5 by default, CIQ_DISPLAY).
#
# It is a rootful Xwayland, and Xwayland draws on a Wayland compositor.  On the desktop's own
# compositor it is a window - one that comes up on your screen with every run, and with
# `runall.sh -j` once per job.  So it gets a compositor of its own that shows nothing: sway on the
# wlroots headless backend, its socket in a folder of its own.  Nothing of a run is then visible;
# look at the screenshots in work/results/ instead.  CIQ_SHOW=1 puts the display on the desktop, to
# watch a run - which is also what happens where sway is not installed.
#
# The harness starts the display by itself when it is missing; this is for stopping it.
# CIQ_GEOMETRY (1400x1000) is its size: the largest devices (Edge 1050, Montana) need 1600x1500.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
DISP=${CIQ_DISPLAY:-:5}
GEOMETRY=${CIQ_GEOMETRY:-1400x1000}
RUN="${TMPDIR:-/tmp}/ciq-display-$(id -u)-${DISP#:}"      # the hidden compositor's runtime folder
xpid() { ps -eo pid,args | awk -v d="$DISP" '($2 ~ /(^|\/)Xwayland$/) && $3 == d {print $1}'; }
spid() { ps -eo pid,args | awk -v c="$RUN/sway.conf" '($2 ~ /(^|\/)sway$/) && $4 == c {print $1}'; }
socket() { ls "$RUN" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1; }
case "${1:-status}" in
  start)
    if [ -z "$(xpid)" ]; then
      mkdir -p "$WORK"
      SOCK=
      if [ -z "${CIQ_SHOW:-}" ] && command -v sway > /dev/null; then
        mkdir -p "$RUN" && chmod 700 "$RUN"
        if [ -z "$(spid)" ]; then
          rm -f "$RUN"/wayland-*
          # No X server of its own (the rootful one below is the display), no background helper;
          # floating, so that the display keeps the size it asks for.
          printf '%s\n' 'xwayland disable' 'swaybg_command -' 'default_border none' \
            'for_window [title=".*"] floating enable' 'output HEADLESS-1 resolution 1920x1600' > "$RUN/sway.conf"
          env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK -u I3SOCK \
            XDG_RUNTIME_DIR="$RUN" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
            setsid nohup sway -c "$RUN/sway.conf" > "$WORK/sway.log" 2>&1 < /dev/null &
        fi
        for _ in $(seq 40); do SOCK=$(socket); [ -n "$SOCK" ] && break; sleep 0.25; done
        [ -n "$SOCK" ] || echo "the hidden compositor did not come up (see $WORK/sway.log); the display will be a window on the desktop"
      fi
      if [ -n "$SOCK" ]; then
        XDG_RUNTIME_DIR="$RUN" WAYLAND_DISPLAY="$SOCK" \
          setsid nohup Xwayland "$DISP" -geometry "$GEOMETRY" -noreset > "$WORK/xwayland.log" 2>&1 < /dev/null &
      else
        setsid nohup Xwayland "$DISP" -geometry "$GEOMETRY" -noreset > "$WORK/xwayland.log" 2>&1 < /dev/null &
      fi
      sleep 1
    fi ;;
  stop)
    for p in $(xpid); do kill "$p" && echo "stopped Xwayland $DISP (pid $p)"; done
    for p in $(spid); do kill "$p" && echo "stopped its compositor (pid $p)"; done ;;
esac
X=$(xpid)
if [ -z "$X" ]; then where="not running"
elif [ -n "$(spid)" ]; then where="pid $X, hidden (CIQ_SHOW=1 at its start shows it on the desktop)"
else where="pid $X, a window on the desktop"; fi
printf 'Xwayland %s: %s\n' "$DISP" "$where"
