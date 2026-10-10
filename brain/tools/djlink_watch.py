#!/usr/bin/env python3
"""Watch the DJ Link connection while you unplug things: one line per change, with how long it
took to come back. For the reconnect tests in docs/sim.md ("Deck connection tests").

    python3 brain/tools/djlink_watch.py                 # deckdash on this computer
    python3 brain/tools/djlink_watch.py http://sektor5.local:8080

Each line: the time, whether deckdash is on the DJ Link network ("joined"), the decks it hears
(number, address), which deck the lights follow and its track, and the par can's USB DMX.
"""
import json
import sys
import time
import urllib.request

DD = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080").rstrip("/")
SB = DD.rsplit(":", 1)[0] + ":8090"


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=1.5) as r:
            return json.loads(r.read())
    except (OSError, ValueError):
        return None


def snapshot():
    sim, st, sb = get(DD + "/api/sim"), get(DD + "/api/state"), get(SB + "/api/state")
    if sim is None:
        return ("deckdash not answering",)
    decks = []
    for p in (st or {}).get("players", []):
        s = p.get("status") or {}
        decks.append(f"#{p.get('number')} {p.get('address', '?')}{' playing' if s.get('playing') else ''}")
    for d in (st or {}).get("devices", []):              # heard on the network but not (yet) a player we track
        if not any(f"#{d.get('number')} " in x for x in decks):
            decks.append(f"#{d.get('number')} {d.get('address', '?')} (heard)")
    live = "lights: no show engine" if sb is None else f"lights follow {sb.get('live') or '-'}" + (f" ({sb.get('title')})" if sb.get("title") else "")
    dmx = "" if sb is None else " · par " + ",".join(f"{v}" for v in (sb.get("dmx") or {}).values())
    return ("joined" if sim.get("djlink") else "NOT JOINED", "sim ON" if sim.get("on") else "",
            "decks: " + (", ".join(sorted(decks)) or "none"), live + dmx)


def main():
    print(f"watching {DD} (Ctrl-C to stop)")
    last, lost_at = None, None
    while True:
        snap = snapshot()
        if snap != last:
            now = time.time()
            note = ""
            if snap[0] != "joined" and (last is None or last[0] == "joined"):
                lost_at = now
            elif snap[0] == "joined" and lost_at is not None:
                note = f"   <- back after {now - lost_at:.1f} s"
                lost_at = None
            print(time.strftime("%H:%M:%S"), " | ".join(x for x in snap if x) + note, flush=True)
            last = snap
        time.sleep(0.5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
