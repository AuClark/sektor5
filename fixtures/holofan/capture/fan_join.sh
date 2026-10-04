#!/bin/bash
FAN_SSID="${FAN_SSID:-Rave-fan}"; FAN_PW="${FAN_PW:-12345678}"; HOME_SSID="$1"; HOME_PW="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"; FIX="$HERE/.."; PY="${PY:-python3}"; T="$FIX/holofan.py"
exec > ~/fan-join.txt 2>&1
echo "== $(date) start"
for try in 1 2 3 4 5 6; do            # the Mac's scan list is flaky: "Could not find network" now and then
  networksetup -setairportnetwork en0 "$FAN_SSID" "$FAN_PW"
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && break 2; sleep 2; done
  echo "== join try $try failed"; sleep 3
done
echo "== on fan wifi: router $(ipconfig getoption en0 router), me $(ipconfig getifaddr en0)"
if [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ]; then
  "$PY" - "$FIX" "$HOME_SSID" "$HOME_PW" <<'PY'
import sys, time, threading; sys.path.insert(0, sys.argv.pop(1)); import holofan as h
conn = h.wait_for_fan(45)
if not conn: print("== no fan connection"); sys.exit()
threading.Thread(target=h.reader, args=(conn,), daemon=True).start()
stop = threading.Event(); threading.Thread(target=h.keepalive, args=(conn, stop), daemon=True).start(); time.sleep(8)
print("== still connected after 8 s with the heartbeat")
for c in ("bright:255",):
    f = h.parse(c); print("== send", c, f.hex(" ")); conn.sendall(f); time.sleep(3)
f = h.join_frame(sys.argv[1], sys.argv[2]); print("== send join", sys.argv[1], len(f), "B"); conn.sendall(f); time.sleep(5)
conn.close()
PY
fi
echo "== back home"
networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
for i in $(seq 1 20); do curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3; done
echo "== home: me $(ipconfig getifaddr en0); waiting for the fan to find us on the home network"
"$PY" "$T" listen 60
echo "== $(date) done; internet $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com)"
