#!/bin/bash
# Put this Mac on the Sektor5 rig router by Ethernet without losing the internet.
# The router has no internet, but its DHCP hands out itself as the gateway, and a USB Ethernet sits
# above Wi-Fi in macOS's service order, so everything online went to the router and died. This gives
# the Ethernet the router is on a fixed address with no gateway, so the internet stays on Wi-Fi and
# the rig is still reachable. Addresses from the repo's .env: S5_ROUTER_IP (the router) and
# S5_MAC_RIG_IP (this Mac on the rig network, a free address in the router's subnet).
#
#   sudo brain/tools/mac_rig_ethernet.sh            plug the router in first, then run this
#   sudo brain/tools/mac_rig_ethernet.sh undo       back to automatic (DHCP) on that Ethernet
#   sudo brain/tools/mac_rig_ethernet.sh permanent
#        Wi-Fi to the top of the network service order, so no Ethernet (either USB adapter, any router)
#        can take the internet while Wi-Fi is up; Ethernet still works for the rig, and for internet
#        when Wi-Fi is off. Needs no router plugged in. Done once; macOS keeps it.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi
[ "$(id -u)" = 0 ] || { echo "Run it with sudo: sudo $0 $*"; exit 1; }

if [ "${1:-}" != permanent ]; then
  : "${S5_ROUTER_IP:?set S5_ROUTER_IP in .env (the rig router)}"
  : "${S5_MAC_RIG_IP:?set S5_MAC_RIG_IP in .env (this Mac on the rig network)}"
fi
ADDR="${S5_MAC_RIG_IP:-}"
NET="${S5_ROUTER_IP:-}"; NET="${NET%.*}."                  # the router's /24

# The Ethernet the router is on: the service whose device has an address in its subnet (DHCP), or for
# undo the one we set.
find_service() {
  networksetup -listnetworkserviceorder | awk '/^\([0-9]+\)/{sub(/^\([0-9]+\) /,""); name=$0} /Device: /{gsub(/.*Device: |\)/,""); print name "|" $0}' |
  while IFS='|' read -r name dev; do
    [ -n "$dev" ] || continue
    ip=$(ipconfig getifaddr "$dev" 2>/dev/null || true)
    case "$ip" in "$NET"*) echo "$name"; return ;; esac
  done
}

if [ "${1:-}" = permanent ]; then
  order=()
  while IFS= read -r line; do order+=("$line"); done < <(networksetup -listnetworkserviceorder | sed -n 's/^([0-9*]*) //p' | grep -vx "Wi-Fi")
  networksetup -ordernetworkservices "Wi-Fi" "${order[@]}"
  echo "Network order now:"; networksetup -listnetworkserviceorder | grep -E "^\([0-9]"
  echo -n "Default route: "; route -n get default 2>/dev/null | awk '/interface/{print $2}'
  exit 0
fi

svc=$(find_service || true)
if [ -z "$svc" ]; then
  echo "No Ethernet on the router (${NET}x) found. Plug the router into the Mac, wait ~10 s for it to"
  echo "hand out an address, and run this again. Services and their addresses now:"
  networksetup -listallhardwareports | awk '/Hardware Port/{p=$0} /Device/{print p " -> " $2}' | while read -r l; do
    d=${l##* }; echo "  $l  $(ipconfig getifaddr "$d" 2>/dev/null || echo '(none)')"; done
  exit 1
fi

if [ "${1:-}" = undo ]; then
  networksetup -setdhcp "$svc"
  echo "\"$svc\" is back on automatic (DHCP)."
  exit 0
fi

networksetup -setmanual "$svc" "$ADDR" 255.255.255.0          # no router given: no default route via it
sleep 2
echo "\"$svc\" is now $ADDR, no gateway."
echo -n "Router ($S5_ROUTER_IP): "; ping -c1 -t2 "$S5_ROUTER_IP" >/dev/null && echo ok || echo "no answer"
echo -n "Internet (1.1.1.1):   "; ping -c1 -t2 1.1.1.1 >/dev/null && echo ok || echo "no answer: check Wi-Fi is connected"
echo -n "Default route:        "; route -n get default 2>/dev/null | awk '/interface/{print $2}'
for h in "${S5_PYRAMID_L_HOST:-rave-pyramid-l.local}" "${S5_PYRAMID_R_HOST:-rave-pyramid-r.local}"; do echo -n "Pyramid $h: "; ping -c1 -t2 "$h" >/dev/null && echo ok || echo "not answering (powered? on the router's Wi-Fi?)"; done
