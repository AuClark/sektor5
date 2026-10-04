#!/bin/bash
# Join the fan, find a clip by name in its file list, power on and play it, rejoin home. Log: ~/fan-play.txt
FAN_SSID='3D-PD42-1024*640-04460071'; HOME_SSID="$1"; HOME_PW="$2"; CLIP="${3:-alive}"
HERE="$(cd "$(dirname "$0")" && pwd)"; FIX="$HERE/.."; PY="${PY:-python3}"
exec > ~/fan-play.txt 2>&1
echo "== $(date) start, looking for clip '$CLIP'"
for try in 1 2 3 4 5 6; do
  networksetup -setairportnetwork en0 "$FAN_SSID" 12345678
  for i in $(seq 1 6); do [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ] && break 2; sleep 2; done
  echo "== join try $try failed"; sleep 3
done
echo "== router $(ipconfig getoption en0 router)"
if [ "$(ipconfig getoption en0 router)" = "192.168.4.1" ]; then
"$PY" - "$FIX" "$CLIP" <<'PY'
import sys, time, threading, socket; sys.path.insert(0, sys.argv.pop(1)); import holofan as h
want = sys.argv[1].lower()
conn = h.wait_for_fan(40)
if not conn: print("== no fan"); sys.exit()
stop = threading.Event(); threading.Thread(target=h.keepalive, args=(conn, stop), daemon=True).start()
data = b""; conn.settimeout(0.5); t = time.time()
while time.time() - t < 6:
    try:
        d = conn.recv(8192)
        if not d: break
        data += d
    except socket.timeout: pass
i = data.find(b"\x5a\x84")
names = []
if i >= 0:
    end = data.find(b"\x00\xf5", i)
    names = data[i + 4:end].decode("utf-8", "replace").split("/")
print("== files:", names)
idx = next((k for k, n in enumerate(names) if n.lower() == want), None)
if idx is None: idx = next((k for k, n in enumerate(names) if want in n.lower()), None)
if idx is None:
    print(f"== no clip named {want!r}"); stop.set(); conn.close(); sys.exit()
print(f"== '{names[idx]}' is clip {idx}")
for c in ("on", "bright:255", f"clip:{idx}", "loop1", "play"):
    f = h.parse(c); print("== send", c, f.hex(" ")); conn.sendall(f); time.sleep(1.5)
time.sleep(4); stop.set(); conn.close()
PY
fi
networksetup -setairportnetwork en0 "$HOME_SSID" "$HOME_PW"
for i in $(seq 1 20); do curl -s -m 4 -o /dev/null https://www.google.com && break; sleep 3; done
echo "== $(date) done; internet $(curl -s -m 4 -o /dev/null -w '%{http_code}' https://www.google.com)"
