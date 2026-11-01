#!/usr/bin/env bash
# Stop every stray test process: runners, simulators, monkeydo.
# Only python processes count as runners - matching the script name alone also matches the shell
# that is invoking this, and killing that kills the caller.
for p in $(ps -eo pid,comm,args | awk '$2 ~ /^python/ && /run\.py/ {print $1}'); do kill "$p" 2>/dev/null && echo "stopped runner $p"; done
sleep 2
for p in $(ps -eo pid,stat,comm | awk '$3=="simulator" && $2 !~ /^Z/ {print $1}'); do kill "$p" 2>/dev/null && echo "stopped simulator $p"; done
sleep 3
for p in $(ps -eo pid,stat,comm | awk '$3=="simulator" && $2 !~ /^Z/ {print $1}'); do kill -9 "$p" 2>/dev/null; done
for p in $(pgrep -f 'garmin.monkeybrains.monkeydodeux'); do kill -INT "$p" 2>/dev/null; done
sleep 1
echo "runners left: $(ps -eo comm,args | awk '$1 ~ /^python/ && /run\.py/' | wc -l)"
echo "simulators left: $(ps -eo pid,stat,comm | awk '$3=="simulator" && $2 !~ /^Z/' | wc -l)"
