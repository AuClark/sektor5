#!/usr/bin/env bash
# Move a WLED board onto the rig's fixture Wi-Fi (the travel router), then find it there.
#
#   fixtures/wled-join.sh <board's current IP>
#
# The Wi-Fi name and password come from the repo's git-ignored .env (S5_FIXTURE_WIFI_SSID,
# S5_FIXTURE_WIFI_PSK, S5_ROUTER_IP); they're never written to the repo. The board is told to use
# only that network and restarted. If it can't connect it opens its own WLED-AP hotspot, so it's
# never lost. Afterwards the script looks for it in the router's DHCP leases (over SSH).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 1 ]] || { echo "usage: $0 <board IP>"; exit 1; }
[[ -f .env ]] || { echo ".env missing (needs S5_FIXTURE_WIFI_SSID / S5_FIXTURE_WIFI_PSK)"; exit 1; }
set -a; . ./.env; set +a
B="$1"; CT='Content-Type: application/json'

info=$(curl -sf -m5 "http://$B/json/info") || { echo "no WLED answering at $B"; exit 1; }
name=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])' <<<"$info")
mac=$(python3 -c 'import sys,json;m=json.load(sys.stdin)["mac"];print(":".join(m[i:i+2] for i in range(0,12,2)))' <<<"$info")
echo "$name ($mac) at $B -> $S5_FIXTURE_WIFI_SSID"

body=$(python3 -c 'import json,os;print(json.dumps({"nw":{"ins":[{"ssid":os.environ["S5_FIXTURE_WIFI_SSID"],"psk":os.environ["S5_FIXTURE_WIFI_PSK"],"ip":[0,0,0,0],"gw":[0,0,0,0],"sn":[255,255,255,0]}]}}))')
curl -sf -m8 -X POST -H "$CT" "http://$B/json/cfg" -d "$body" >/dev/null
curl -s -m5 -X POST -H "$CT" "http://$B/json/state" -d '{"rb":true}' >/dev/null || true
echo "restarting; waiting for it on the router (up to 60 s)..."

for _ in $(seq 1 30); do
  lease=$(ssh -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=4 "root@${S5_ROUTER_IP:-192.168.8.1}" \
          "grep -i '$mac' /tmp/dhcp.leases" 2>/dev/null || true)
  if [[ -n "$lease" ]]; then
    ip=$(awk '{print $3}' <<<"$lease")
    if curl -sf -m3 "http://$ip/json/info" >/dev/null; then echo "OK: $name is on $S5_FIXTURE_WIFI_SSID at $ip"; exit 0; fi
  fi
  sleep 2
done
echo "not seen on the router yet. If its old address still answers it didn't restart (press EN or power-cycle it);"
echo "if neither answers, look for a WLED-AP hotspot (password wled1234) and set the Wi-Fi from its page."
exit 1
