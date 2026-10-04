#!/bin/bash
FAN_SSID="${FAN_SSID:-Rave-fan}"; FAN_PW="${FAN_PW:-12345678}"; HOME_SSID="$1"; HOME_PW="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"; FIX="$HERE/.."; PY="${PY:-python3}"
exec > ~/fan-info.txt 2>&1
echo "== $(date) start"
for try in 1 2 3 4 5 6; do
  networksetup -setairportnetwork en0 "$FAN_SSID" "$FAN_PW"
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && break 2; sleep 2; done
  echo "== join try $try failed"; sleep 3
done
echo "== router $(ipconfig getoption en0 router)"
if [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ]; then
"$PY" - "$FIX" "${OUT:-$HERE/fan_rx.bin}" <<'PY'
import sys, time, threading, socket; sys.path.insert(0, sys.argv.pop(1)); import holofan as h
conn = h.wait_for_fan(40)
if not conn: print("== no fan"); sys.exit()
stop = threading.Event(); threading.Thread(target=h.keepalive, args=(conn, stop), daemon=True).start()
data = b""; conn.settimeout(0.5); t = time.time()
while time.time() - t < 10:
    try:
        d = conn.recv(8192)
        if not d: break
        data += d
    except socket.timeout: pass
open(sys.argv[1], "wb").write(data); print("== saved", len(data), "bytes"); stop.set(); conn.close()
PY
fi
networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
for i in $(seq 1 20); do curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3; done
echo "== $(date) done; internet $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com)"
