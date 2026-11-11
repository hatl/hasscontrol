#!/usr/bin/env bash
# Run a command with a simulator world of its own, so that several can run side by side.
#
# Only one simulator can exist on a machine: it listens on TCP 1234, keeps its apps under
# /tmp/com.garmin.connectiq and its settings in ~/.Garmin/ConnectIQ/simulator.ini, and takes any
# other simulator process for itself.  bubblewrap gives the command a network, a /tmp, a process
# table and a settings folder of its own; the mocks, the X display and the simulator the harness
# starts in there are invisible to every other run and end with the command.  Your own
# simulator.ini is not touched at all.
# usage: sandbox.sh <command> [args ...]        (needs bwrap; runall.sh -j uses this)
set -u
G="$HOME/.Garmin/ConnectIQ"
command -v bwrap > /dev/null || { echo "sandbox.sh needs bubblewrap (bwrap)"; exit 2; }
exec bwrap --dev-bind / / --proc /proc --tmpfs /tmp --unshare-net --unshare-pid --die-with-parent \
  --tmpfs "$G" --ro-bind "$G/Devices" "$G/Devices" --ro-bind "$G/Sdks" "$G/Sdks" \
  --ro-bind "$G/Fonts" "$G/Fonts" --ro-bind "$G/current-sdk.cfg" "$G/current-sdk.cfg" \
  "$@"
