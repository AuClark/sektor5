#!/bin/bash
FAN_SSID="${FAN_SSID:-Rave-fan}"; FAN_PW="${FAN_PW:-12345678}"; HOME_SSID="$1"; HOME_PW="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"; FIX="$HERE/.."; PY="${PY:-python3}"
exec > ~/fan-relay.txt 2>&1
echo "== $(date) waiting 45 s so the instructions can be read"; sleep 45
if [ -n "$USB" ]; then   # reach the app over a USB cable instead of Wi-Fi; the phone can stay off the fan's network
  SERIAL=$(adb devices | awk '$2 == "device" && $1 !~ /_adb-tls/ {print $1; exit}')
  [ -z "$SERIAL" ] && { echo "== no phone on USB (wireless adb drops when the Mac changes network)"; exit 1; }
  adb -s "$SERIAL" forward tcp:6667 tcp:6666 && export APP=127.0.0.1:6667
  adb -s "$SERIAL" logcat -c; adb -s "$SERIAL" logcat -v time > "${OUT:-$HERE/relay.bin}.logcat.txt" 2>&1 & LOGCAT=$!
  echo "== phone $SERIAL: app forwarded to $APP, logcat recording"
fi
for try in 1 2 3 4 5 6; do
  networksetup -setairportnetwork en0 "$FAN_SSID" "$FAN_PW"
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && break 2; sleep 2; done
  echo "== join try $try failed"; sleep 3
done
echo "== router $(ipconfig getoption en0 router), me $(ipconfig getifaddr en0)"
[ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && "$PY" "$HERE/relay.py" "${OUT:-$HERE/relay.bin}"
[ -n "$LOGCAT" ] && kill $LOGCAT; [ -n "$SERIAL" ] && adb -s "$SERIAL" forward --remove tcp:6667
networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
for i in $(seq 1 20); do curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3; done
echo "== $(date) done; internet $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com)"
