#!/bin/bash
# Join the fan's Wi-Fi, upload a picture with our own encoder and play it, rejoin home. Log: ~/fan-upload.txt
# PY needs numpy and opencv (pip install numpy opencv-python-headless).
FAN_SSID='3D-PD42-1024*640-04460071'; HOME_SSID="$1"; HOME_PW="$2"; PIC="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"; FIX="$HERE/.."; PY="${PY:-python3}"
PIC="$(cd "$(dirname "$PIC")" && pwd)/$(basename "$PIC")"
exec > ~/fan-upload.txt 2>&1
echo "== $(date) uploading $PIC"
for try in 1 2 3 4 5 6; do
  networksetup -setairportnetwork en0 "$FAN_SSID" 12345678
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && break 2; sleep 2; done
  echo "== join try $try failed"; sleep 3
done
echo "== router $(ipconfig getoption en0 router), me $(ipconfig getifaddr en0)"
[ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && (cd "$FIX" && "$PY" holofan.py upload "$PIC" --play)
networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
for i in $(seq 1 20); do curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3; done
echo "== $(date) done; internet $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com)"
