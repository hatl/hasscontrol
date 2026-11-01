#!/usr/bin/env bash
# start|stop|status the two mock Home Assistant servers (plain http 8123, TLS 8124).
# Processes are found by the port they listen on, never by a command-line pattern: a pattern that
# names the script also matches the shell that is running this, and killing that kills the caller.
set -u
S=$(cd "$(dirname "$0")/.." && pwd)
pid_on_port() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }
case "${1:-status}" in
  stop)
    for port in 8123 8124; do p=$(pid_on_port $port); [ -n "$p" ] && kill "$p" && echo "stopped $port (pid $p)"; done
    sleep 1 ;;
  start)
    cd "$S/mock"
    [ -z "$(pid_on_port 8123)" ] && setsid nohup python3 -I "$S/scripts/mock_ha.py" --port 8123 > "$S/mock/http.log" 2>&1 < /dev/null &
    [ -z "$(pid_on_port 8124)" ] && setsid nohup python3 -I "$S/scripts/mock_ha.py" --port 8124 --cert "$S/mock/tls/cert.pem" --key "$S/mock/tls/key.pem" > "$S/mock/tls.log" 2>&1 < /dev/null &
    sleep 2 ;;
esac
for port in 8123 8124; do printf '%s: %s\n' "$port" "$(pid_on_port $port | sed 's/^$/not running/')"; done
