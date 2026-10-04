#!/bin/bash
# Join the fan's Wi-Fi, list everything it listens on and what it sends, rejoin home. Read-only. Log: ~/fan-probe.txt
FAN_SSID="${FAN_SSID:-Rave-fan}"; FAN_PW="${FAN_PW:-12345678}"; HOME_SSID="$1"; HOME_PW="$2"; FAN=192.168.4.1
exec > >(tee ~/fan-probe.txt) 2>&1          # shows progress here too
echo "Takes about 3-5 min; the Mac is off the internet until it says done."
echo "== $(date) start"
for try in 1 2 3 4 5 6; do
  networksetup -setairportnetwork en0 "$FAN_SSID" "$FAN_PW"
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "$FAN" ] && break 2; sleep 2; done
  echo "== join try $try failed"; sleep 3
done
echo "== router $(ipconfig getoption en0 router), me $(ipconfig getifaddr en0)"
if [ "$(ipconfig getoption en0 router)" = "$FAN" ]; then
  echo "== passive capture 30 s (everything to/from the fan, broadcasts, mDNS)"
  sudo -n true 2>/dev/null && SUDO="sudo -n" || SUDO=""
  $SUDO tcpdump -i en0 -n -c 400 -w "$HOME/fan-probe.pcap" "host $FAN or broadcast or multicast" 2>&1 &
  TD=$!; sleep 30; kill $TD 2>/dev/null
  [ -f "$HOME/fan-probe.pcap" ] && tcpdump -n -r "$HOME/fan-probe.pcap" 2>/dev/null | head -60
  echo "== TCP: all 65535 ports"
  nmap -Pn -p- -T4 --min-rate 2000 --max-retries 1 -sT --stats-every 20s -oN "$HOME/fan-ports.txt" $FAN | tee /dev/tty
  OPEN=$(grep -E "^[0-9]+/tcp +open" "$HOME/fan-ports.txt" | cut -d/ -f1 | paste -sd, -)
  echo "== open TCP ports: ${OPEN:-none}"
  [ -n "$OPEN" ] && nmap -Pn -sT -sV -p "$OPEN" $FAN
  echo "== UDP: common ports (needs sudo for -sU; skipped otherwise)"
  [ -n "$SUDO" ] && $SUDO nmap -Pn -sU --top-ports 50 -T4 $FAN
  echo "== HTTP on any open web-looking port"
  for p in 80 8080 8000 81 443; do curl -s -m 3 -i "http://$FAN:$p/" | head -15 && echo "-- ($p)"; done
fi
networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
for i in $(seq 1 20); do curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3; done
echo "== $(date) done; internet $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com)"
