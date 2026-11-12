#!/usr/bin/env bash
# start|stop|status the two mock Home Assistant servers (plain http 8123, TLS 8124).
# Processes are found by the port they listen on, never by a command-line pattern: a pattern that
# names the script also matches the shell that is running this, and killing that kills the caller.
# The TLS mock's self-signed certificate is generated on first use (work/mock/tls/).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${CIQ_WORK:-$HERE/work}
MOCK="$WORK/mock"
pid_on_port() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }
case "${1:-status}" in
  stop)
    for port in 8123 8124; do p=$(pid_on_port $port); [ -n "$p" ] && kill "$p" && echo "stopped $port (pid $p)"; done
    sleep 1 ;;
  start)
    mkdir -p "$MOCK/tls"
    if [ ! -f "$MOCK/tls/cert.pem" ]; then
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=127.0.0.1 \
        -addext subjectAltName=IP:127.0.0.1 -keyout "$MOCK/tls/key.pem" -out "$MOCK/tls/cert.pem" 2>/dev/null \
        && echo "generated $MOCK/tls/cert.pem"
    fi
    cd "$MOCK"
    # `if`, not `[ ... ] && server &`: that puts a whole subshell into the background, which keeps
    # this script's stdout open for as long as the server runs - and a caller that captures the
    # output (capacity.py, live.py) then waits for ever.
    if [ -z "$(pid_on_port 8123)" ]; then
      setsid nohup python3 -I "$HERE/mock_ha.py" --port 8123 > "$MOCK/http.log" 2>&1 < /dev/null &
    fi
    if [ -z "$(pid_on_port 8124)" ]; then
      setsid nohup python3 -I "$HERE/mock_ha.py" --port 8124 --cert "$MOCK/tls/cert.pem" --key "$MOCK/tls/key.pem" > "$MOCK/tls.log" 2>&1 < /dev/null &
    fi
    sleep 2 ;;
esac
for port in 8123 8124; do printf '%s: %s\n' "$port" "$(pid_on_port $port | sed 's/^$/not running/')"; done
