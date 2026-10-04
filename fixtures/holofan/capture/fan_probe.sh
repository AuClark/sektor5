#!/bin/bash
# Join the fan's Wi-Fi, list everything it listens on and what it sends, rejoin home. Read-only.
# Shows which step it's on, what that step is doing, and progress within it. Log: ~/fan-probe.txt
#   sudo -v && fan_probe.sh "<home ssid>" "<home password>"
FAN_SSID="${FAN_SSID:-Rave-fan}"; FAN_PW="${FAN_PW:-12345678}"; HOME_SSID="$1"; HOME_PW="$2"; FAN=192.168.4.1
CAPTURE_SECS=30; STEPS=7; T0=$(date +%s)
exec > >(tee ~/fan-probe.txt) 2>&1

elapsed() { local s=$(( $(date +%s) - T0 )); printf "%d:%02d" $((s / 60)) $((s % 60)); }
step() {     # step N "what it's doing"
  N=$1; local done=$(( (N - 1) * 100 / STEPS ))
  echo; echo "[$(date +%H:%M:%S) | ${N}/${STEPS} | overall ${done}% | $(elapsed) elapsed]"
  echo "== $2"
}
note() { echo "   $*"; }
bar() {      # bar DONE TOTAL "label": one updating line
  local w=30 f=$(( $1 * 30 / ($2 > 0 ? $2 : 1) ))
  printf "\r   [%-${w}s] %3d%%  %s   " "$(printf '%*s' $f '' | tr ' ' '#')" $(( $1 * 100 / ($2 > 0 ? $2 : 1) )) "$3"
}
nmap_progress() {   # turn nmap's --stats-every lines into progress lines
  while IFS= read -r l; do
    case "$l" in
      *"% done"*) p=$(echo "$l" | sed -E 's/.*About ([0-9.]+)% done.*/\1/'); etc=$(echo "$l" | sed -nE 's/.*ETC: ([0-9:]+).*/\1/p')
                  note "${p}% of this scan done${etc:+, expected to finish at $etc}";;
      *"/tcp "*|*"/udp "*|*"Nmap scan report"*|*"PORT "*|*"Nmap done"*|*"Not shown"*|*"All "*) note "$l";;
    esac
  done
}
cleanup_home() {
  step 7 "Rejoining your home Wi-Fi ($HOME_SSID)"
  networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
  for i in $(seq 1 20); do
    bar $i 20 "waiting for internet (try $i of 20)"
    curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3
  done; echo
  note "internet: $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com) (200 = back online)"
  echo; echo "[$(date +%H:%M:%S) | done | overall 100% | $(elapsed) total] Results: ~/fan-probe.txt, ~/fan-ports.txt, ~/fan-probe.pcap"
}
trap 'echo; note "stopped early: rejoining home first"; cleanup_home; exit 1' INT TERM

echo "Fan probe: $STEPS steps, about 5 minutes at most. The Mac is off the internet until step 7 finishes."
sudo -n true 2>/dev/null && SUDO="sudo -n" || { SUDO=""; echo "(no sudo: the traffic capture and UDP scan will be skipped; run 'sudo -v' first to include them)"; }

step 1 "Joining the fan's Wi-Fi ($FAN_SSID)"
for try in 1 2 3 4 5 6; do
  bar $try 6 "join attempt $try of 6"
  networksetup -setairportnetwork en0 "$FAN_SSID" "$FAN_PW" >/dev/null 2>&1
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "$FAN" ] && break 2; sleep 2; done
  sleep 3
done; echo
if [ "$(ipconfig getoption en0 router)" != "$FAN" ]; then
  note "couldn't join $FAN_SSID (is the fan on?)"; cleanup_home; exit 1
fi
note "on $FAN_SSID: the fan is $FAN, the Mac is $(ipconfig getifaddr en0)"

step 2 "Recording everything the fan sends for ${CAPTURE_SECS} s (broadcasts, mDNS, anything unprompted)"
if [ -n "$SUDO" ]; then
  $SUDO tcpdump -i en0 -n -w "$HOME/fan-probe.pcap" "host $FAN or broadcast or multicast" >/dev/null 2>&1 & TD=$!
  for s in $(seq 1 $CAPTURE_SECS); do bar $s $CAPTURE_SECS "$((CAPTURE_SECS - s)) s left"; sleep 1; done; echo
  $SUDO kill $TD 2>/dev/null; sleep 1
  n=$(tcpdump -n -r "$HOME/fan-probe.pcap" "src host $FAN and not icmp and not arp" 2>/dev/null | wc -l | tr -d ' ')
  note "packets the fan sent on its own (not replies to the Mac): $n"
  tcpdump -n -r "$HOME/fan-probe.pcap" "src host $FAN and not icmp and not arp" 2>/dev/null | head -20 | sed 's/^/   /'
else note "skipped (needs sudo)"; fi

step 3 "Scanning the 1,000 most common TCP ports plus the usual ESP32 ones (what the fan listens on)"
# The fan ignores closed ports instead of refusing them, so every miss is a timeout: keep the list short
# and the waits small (it's one Wi-Fi hop away). ESP32 extras: 3232 ArduinoOTA, 8266, 6666 app, 23 telnet...
ESP_PORTS="21,22,23,53,80,81,443,554,1883,2323,3232,5000,5555,6666,6667,7777,8000,8080,8081,8088,8266,8443,8888,8988,9000,9999,23456,50000"
nmap -Pn -sT --top-ports 1000 -p "T:$ESP_PORTS" -T4 --max-retries 0 --initial-rtt-timeout 80ms --max-rtt-timeout 250ms \
     --host-timeout 4m --stats-every 10s -oN "$HOME/fan-ports.txt" $FAN 2>&1 | nmap_progress
OPEN=$(grep -E "^[0-9]+/tcp +open" "$HOME/fan-ports.txt" | cut -d/ -f1 | paste -sd, -)
note "open TCP ports: ${OPEN:-none}"

step 4 "Identifying the services on the open ports"
if [ -n "$OPEN" ]; then nmap -Pn -sT -sV -p "$OPEN" --stats-every 10s $FAN 2>&1 | nmap_progress
else note "nothing open to identify"; fi

step 5 "Scanning the 50 most common UDP ports"
if [ -n "$SUDO" ]; then $SUDO nmap -Pn -sU --top-ports 50 -p "U:8988,6666,5353,1900" -T4 --max-retries 1 --host-timeout 3m --stats-every 10s $FAN 2>&1 | nmap_progress
else note "skipped (needs sudo)"; fi

step 6 "Asking any web-looking ports for a page"
PORTS="80 8080 8000 81 443"; i=0
for p in $PORTS; do
  i=$((i + 1)); bar $i 5 "port $p"
  r=$(curl -s -m 3 -i "http://$FAN:$p/" | head -12)
  [ -n "$r" ] && { echo; note "port $p answered:"; echo "$r" | sed 's/^/     /'; }
done; echo

trap - INT TERM
cleanup_home
