"""The live track's waveform, per beat, for sketches.

rekordbox analyses every track when the USB is prepared; the decks share that colour
waveform over Pro DJ Link and deckdash already fetches it (/api/wavedetail/N, 150 frames a
second: height 0-31 and r, g, b for bass, mids, highs) along with the beat grid
(/api/timeline/N, beatMs). We follow showbrain's live deck, and when its track changes we
resample the waveform onto the beat grid at its full detail: native_spb() samples per beat, one
per rekordbox frame at the track's tempo (about 70 at 128 BPM), so a sketch can look it up by
u_beat and it stays locked to the music however the DJ changes the tempo.

The result is packed as RGBA bytes (height, bass, mids, highs) in a TEX_W-wide texture and
sent to the pages over the visuals service's event stream, once per track.

Without the decks (at home) it uses a waveform captured from the rig with
tools/capture_wave.py (state/wave-sample.*), or else a synthetic demo track, looped.
"""
import base64
import json
import math
import threading
import time
import urllib.request

SPB = 32                   # samples per beat for the demo track; a real track gets native_spb()
RB_FPS = 150               # rekordbox's detail waveform: frames a second
TEX_W = 256                # texture width; height grows with the track
POLL_S = 2.0


def native_spb(beat_ms):
    """Samples per beat that keep every frame of rekordbox's waveform at this track's tempo
    (150 frames a second: about 70 a beat at 128 BPM, 64 at 140, 75 at 120), so nothing is lost."""
    gaps = sorted(b - a for a, b in zip(beat_ms, beat_ms[1:]) if b > a)
    beat = gaps[len(gaps) // 2] if gaps else 500
    return max(8, min(128, math.ceil(beat / 1000 * RB_FPS)))


def pack(samples, meta, spb=SPB):
    """samples: list of (height, r, g, b) 0-255, spb a beat. Returns the message the pages get."""
    n = len(samples)
    h = max(1, math.ceil(n / TEX_W))
    buf = bytearray(TEX_W * h * 4)
    for i, s in enumerate(samples):
        buf[i * 4:i * 4 + 4] = bytes(s)
    return {**meta, "beats": n // spb, "spb": spb, "w": TEX_W, "h": h,
            "data": base64.b64encode(bytes(buf)).decode("ascii")}


def resample(detail, beat_ms, spb=SPB):
    """Detail waveform bytes + beat times (ms) -> spb samples per beat (loudest frame in each slice)."""
    frames = len(detail) // 4
    out = []
    nb = len(beat_ms)
    for b in range(nb):
        t0 = beat_ms[b]
        t1 = beat_ms[b + 1] if b + 1 < nb else t0 + (t0 - beat_ms[b - 1] if b else 500)
        for j in range(spb):
            f0 = int((t0 + (t1 - t0) * j / spb) * 0.15)
            f1 = max(f0 + 1, int((t0 + (t1 - t0) * (j + 1) / spb) * 0.15))
            best = (0, 0, 0, 0)
            for f in range(max(0, f0), min(frames, f1)):
                hgt = detail[f * 4]
                if hgt >= best[0]:
                    best = (hgt, detail[f * 4 + 1], detail[f * 4 + 2], detail[f * 4 + 3])
            out.append((min(255, best[0] * 255 // 31), best[1], best[2], best[3]))
    return out


def demo():
    """A made-up 128-bar dance track: intro, groove, breakdown, build, drop, groove, outro."""
    def hsh(x):
        return (math.sin(x * 12.9898) * 43758.5453) % 1.0
    out = []
    for b in range(512):
        bar = b // 4 + 1
        intro, groove, brk, build, drop = bar <= 16, 16 < bar <= 32, 32 < bar <= 48, 48 < bar <= 56, 56 < bar <= 88
        outro = bar > 104
        for j in range(SPB):
            ph = j / SPB
            kick = math.exp(-ph * 7) if not (brk or build) else 0.0
            if outro:
                kick *= max(0.2, 1 - (bar - 104) / 24)
            hat = 0.35 * math.exp(-abs(ph - 0.5) * 20) if not brk else 0.0
            bass = (0.5 + 0.2 * hsh(b * 8 + j)) * (0.5 + 0.5 * math.cos(ph * 2 * math.pi * 2)) if (groove or drop) else 0.0
            pads = 0.35 if brk else 0.15 if drop else 0.05
            snare = 0.0
            if build:
                rate = 2 ** ((bar - 49) // 2)                      # 1, 2, 4, 8 hits a beat
                snare = 0.3 + 0.5 * (bar - 49) / 8 * math.exp(-((ph * rate) % 1) * 5)
            if drop:
                kick, bass = kick * 1.0, bass * 1.3
            r = min(1.0, kick * 0.9 + bass * 0.8)
            g = min(1.0, pads + bass * 0.3 + snare * 0.6)
            bl = min(1.0, hat + snare * 0.8 + (0.15 if drop else 0.0))
            h = min(1.0, max(kick, bass * 0.8, pads, snare, hat) * (1.0 if drop else 0.85) + 0.05 * hsh(b + j * 0.1))
            out.append((int(h * 255), int(r * 255), int(g * 255), int(bl * 255)))
    return pack(out, {"key": "demo", "source": "demo", "title": "Demo track (no decks)", "loop": True})


def load_sample(state_dir):
    try:
        detail = (state_dir / "wave-sample.bin").read_bytes()
        meta = json.loads((state_dir / "wave-sample.json").read_text())
        spb = native_spb(meta["beatMs"])
        return pack(resample(detail, meta["beatMs"], spb),
                    {"key": "sample", "source": "sample", "title": meta.get("title") or "Captured track", "loop": True}, spb)
    except (OSError, ValueError, KeyError):
        return None


def get(url, timeout=2.0):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


class Follower:
    """Follows the live deck's track; calls on_wave(msg) whenever the waveform changes."""

    def __init__(self, deckdash, state_dir, live_player, on_wave):
        self.deckdash, self.state_dir, self.live_player, self.on_wave = deckdash, state_dir, live_player, on_wave
        self.key = None
        self.current = None

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                self._tick()
            except Exception:
                pass
            time.sleep(POLL_S)

    def _set(self, msg):
        self.key, self.current = msg["key"], msg
        self.on_wave(msg)

    def _tick(self):
        live = self.live_player()
        if live:
            try:
                st = json.loads(get(f"{self.deckdash}/api/state"))
                p = next((p for p in st.get("players", []) if p.get("number") == live), None)
                if p and p.get("waveformKey") and p.get("timelineKey"):
                    key = f"live:{live}:{p['waveformKey']}:{p['timelineKey']}"
                    if key != self.key:
                        detail = get(f"{self.deckdash}/api/wavedetail/{live}", timeout=5.0)
                        tl = json.loads(get(f"{self.deckdash}/api/timeline/{live}", timeout=5.0))
                        title = (p.get("track") or {}).get("title") or tl.get("title")
                        spb = native_spb(tl["beatMs"])
                        self._set(pack(resample(detail, tl["beatMs"], spb),
                                       {"key": key, "source": "live", "title": title, "player": live, "loop": False}, spb))
                    return
            except (OSError, ValueError, KeyError):
                pass
        if self.current is None:                                   # nothing live yet: sample, else demo
            self._set(load_sample(self.state_dir) or demo())
