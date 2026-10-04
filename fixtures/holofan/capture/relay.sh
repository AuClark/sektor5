#!/bin/bash
FAN_SSID='3D-PD42-1024*640-04460071'; HOME_SSID="$1"; HOME_PW="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"; FIX="$HERE/.."; PY="${PY:-python3}"
exec > ~/fan-relay.txt 2>&1
echo "== $(date) waiting 45 s so the instructions can be read"; sleep 45
for try in 1 2 3 4 5 6; do
  networksetup -setairportnetwork en0 "$FAN_SSID" 12345678
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && break 2; sleep 2; done
  echo "== join try $try failed"; sleep 3
done
echo "== router $(ipconfig getoption en0 router), me $(ipconfig getifaddr en0)"
[ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && "$PY" "$HERE/relay.py" "${OUT:-$HERE/relay.bin}"
networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
for i in $(seq 1 20); do curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3; done
echo "== $(date) done; internet $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com)"
