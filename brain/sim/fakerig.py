#!/usr/bin/env python3
"""Synthetic rig: stands in for deckdash (the decks) and the DJM mixer, so the whole app runs on a
laptop with no hardware connected. Started by brain/sim/run.sh; see docs/sim.md.

It plays an endless, beat-matched DJ set of generated tracks on two virtual XDJs:
  - each track has a phrase structure (intro, grooves, breakdowns, builds, drops, outro), and the
    timeline, waveforms and library entries the real deckdash would give for it;
  - the next track is mixed in over the outgoing track's outro: synced to its tempo, bass swapped
    halfway, and the mixer's channel levels, share and bass-out follow the fades;
  - you can also drive it from the dashboard: load, play, stop, sync and master work.

Speaks the same protocols as the real thing:
  :8080          the dashboard page and its API (/api/state, /api/events, /api/timeline/N,
                 /api/waveform/N, /api/wavedetail/N, /api/library/..., /api/deck, /api/tempo)
  UDP :9100      showbrain's feed: 20 Hz deck status, a packet per beat, and mixer messages

    python3 brain/sim/fakerig.py [--no-auto] [--bpm 126] [--port 8080] [--feed 9100]
"""
import argparse
import json
import math
import random
import socket
import threading
import time
import urllib.request

import realtracks
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]                 # brain/
WEB = ROOT / "deckdash" / "web"
COMMON = ROOT / "common" / "web"

ap = argparse.ArgumentParser()
ap.add_argument("--no-auto", action="store_true", help="don't mix tracks automatically")
ap.add_argument("--bpm", type=float, default=126.0, help="tempo of the set")
ap.add_argument("--port", type=int, default=8080)
ap.add_argument("--feed", type=int, default=9100, help="showbrain's UDP feed port")
ap.add_argument("--tracks", default="/srv/rave/sim/tracks", help="the DJ's own tracks with rekordbox analysis (realtracks.py); used if there")
ARGS = ap.parse_args()

# ---------------------------------------------------------------- tracks
WORDS_A = ["Steel", "Sector", "Night", "Voltage", "Iron", "Neon", "Concrete", "Signal", "Furnace", "Chrome",
           "Pulse", "Static", "Hydraulic", "Carbon", "Tunnel", "Rust", "Laser", "Pressure", "Foundry", "Circuit"]
WORDS_B = ["Shift", "Floor", "Engine", "Drift", "Ritual", "Machine", "Rain", "Weight", "Garden", "Bloom",
           "Theory", "Motion", "System", "Frequency", "Heat", "Code", "Division", "Horizon", "Grid", "Protocol"]
ARTISTS = ["Kreo", "Vantablack Unit", "Mara Oko", "DJ Tessellate", "Low Orbit", "Halden", "Sub Rosa", "Juno Vale",
           "Paragon 9", "The Welders", "Nyx & Arlo", "Kiln"]
GENRES = ["Techno", "Tech House", "Melodic Techno", "Progressive House", "Trance"]
KEYS = ["8A", "9A", "10A", "11A", "4A", "5A", "6A", "7A", "8B", "9B", "10B", "12A"]
SECTION_ENERGY = {"intro": 0.45, "groove": 0.7, "breakdown": 0.25, "build": 0.6, "drop": 1.0, "outro": 0.45}
SECTION_BASS = {"intro": 0.8, "groove": 0.9, "breakdown": 0.08, "build": 0.3, "drop": 1.0, "outro": 0.8}


def make_track(i):
    rnd = random.Random(i * 7919)
    plan = [("intro", rnd.choice([16, 32])), ("groove", 16), ("breakdown", rnd.choice([8, 16])), ("build", 8),
            ("drop", 16), ("groove", rnd.choice([8, 16])), ("breakdown", 8), ("build", rnd.choice([8, 16])),
            ("drop", 16), ("groove", 8), ("outro", 16)]
    return {"id": i + 1, "title": f"{rnd.choice(WORDS_A)} {rnd.choice(WORDS_B)} ({rnd.choice(['Extended', 'Original', 'Club'])} Mix)",
            "artist": rnd.choice(ARTISTS), "genre": rnd.choice(GENRES), "key": rnd.choice(KEYS),
            "bpm": round(rnd.uniform(122, 132), 2), "plan": plan, "label": "Sektor5 Sim", "year": 2026,
            "rating": rnd.randint(2, 5), "color": rnd.choice([None, "Pink", "Aqua", "Green", "Orange"])}


TRACKS = [make_track(i) for i in range(40)]
for t in TRACKS:
    bars, sections = 1, []
    for typ, n in t["plan"]:
        sections.append((typ, bars, bars + n - 1))
        bars += n
    t["bars"] = bars - 1
    t["beats"] = t["bars"] * 4
    t["sections"] = sections
    t["beat_ms"] = 60000.0 / t["bpm"]
    t["dur"] = int(t["beats"] * t["beat_ms"] / 1000) + 1
    t["drops"] = [(s, sections[k - 1][1]) for k, (typ, s, e) in enumerate(sections) if typ == "drop"]   # (bar, build start bar)
    t["outro_bar"] = next(s for typ, s, e in sections if typ == "outro")


REAL = realtracks.load_all(ARGS.tracks)
if REAL:
    print(f"{len(REAL)} real tracks from {ARGS.tracks}: " + ", ".join(f"{t['artist']} - {t['title']} ({t['structure']})" for t in REAL), flush=True)
TRACKS = REAL + TRACKS


def bar_ms(t, bar):
    """Where a bar starts in the track (real tracks' first downbeat isn't at 0 ms)."""
    return t.get("offset_ms", 0) + (bar - 1) * 4 * t["beat_ms"]


def section_at(t, bar):
    for typ, s, e in t["sections"]:
        if s <= bar <= e:
            return typ, s, e
    return "outro", t["bars"], t["bars"]


def bar_energy(t, bar):
    typ, s, e = section_at(t, bar)
    base = SECTION_ENERGY[typ]
    if typ == "build":
        base = 0.35 + 0.5 * (bar - s) / max(1, e - s)
    return base


def timeline(t, ref):
    fb = [1 + 4 * b for b in range(t["bars"])]
    off = t.get("offset_ms", 0)
    return {"ref": ref, "title": t["title"], "bars": t["bars"], "beats": t["beats"], "beatInBar": 1, "beatInBeat": 1,
            "outroBar": t["outro_bar"],
            "drops": [{"bar": b, "gridBar": b, "beat": fb[b - 1], "ms": int(off + fb[b - 1] * t["beat_ms"] - t["beat_ms"]),
                       "lift": 3.2, "confidence": 0.9, "cue": True, "buildStartBar": bs, "buildStartBeat": fb[bs - 1]}
                      for b, bs in t["drops"]],
            "sections": [{"type": typ, "startBar": s, "endBar": e, "startBeat": fb[s - 1],
                          "endBeat": fb[e] - 1 if e < t["bars"] else t["beats"]} for typ, s, e in t["sections"]],
            "energy": t.get("energy_bars") or [round(bar_energy(t, b) * 100) for b in range(1, t["bars"] + 1)],
            "bass": t.get("bass_bars") or [round(SECTION_BASS[section_at(t, b)[0]] * 100) for b in range(1, t["bars"] + 1)],
            "barFirstBeat": fb, "beatMs": [int(off + i * t["beat_ms"]) for i in range(t["beats"])]}


def wave_detail(t):
    """150 frames/s, 4 bytes per frame (height 0-31, r, g, b), shaped by the track's sections."""
    frames = int(t["dur"] * 150)
    out = bytearray(frames * 4)
    rnd = random.Random(t["id"])
    for f in range(frames):
        ms = f / 0.15
        beat = ms / t["beat_ms"]
        bar = int(beat // 4) + 1
        typ = section_at(t, min(bar, t["bars"]))[0]
        e, bass = bar_energy(t, bar), SECTION_BASS[typ]
        kick = math.exp(-(beat % 1) * 7) * bass
        hat = 0.35 * math.exp(-((beat + 0.5) % 1) * 12) * (0.4 if typ == "breakdown" else 1)
        h = min(31, int(3 + 22 * e * (0.35 + 0.65 * kick) + 6 * hat + rnd.random() * 3))
        out[f * 4:f * 4 + 4] = bytes((h, int(60 + 190 * kick), int(70 + 120 * (1 - kick) * e), int(120 + 130 * hat)))
    return bytes(out)


def wave_overview(t, seg=400):
    if t.get("detail_bytes"):                     # a real track: from its rekordbox colour waveform
        d, hs, cs = t["detail_bytes"], [], []
        n = len(d) // 4
        for i in range(seg):
            a, z = i * n // seg, max(i * n // seg + 1, (i + 1) * n // seg)
            fr = [d[k * 4:k * 4 + 4] for k in range(a, z)]
            hs.append(max(f[0] for f in fr))
            r, g, b = (sum(f[j] for f in fr) // len(fr) for j in (1, 2, 3))
            cs.append(f"#{r:02x}{g:02x}{b:02x}")
        return {"segments": seg, "maxHeight": 31, "color": True, "heights": hs, "colors": cs}
    hs, cs = [], []
    for i in range(seg):
        bar = 1 + int(i / seg * t["bars"])
        typ = section_at(t, bar)[0]
        e = bar_energy(t, bar)
        hs.append(int(3 + 26 * e))
        cs.append({"drop": "#ff5a1f", "build": "#f2b84b", "breakdown": "#5b8cff", "groove": "#e6e6e6"}.get(typ, "#9a9a9a"))
    return {"segments": seg, "maxHeight": 31, "color": True, "heights": hs, "colors": cs}


# ---------------------------------------------------------------- decks
class Deck:
    def __init__(self, n):
        self.n = n
        self.track = None
        self.ref = None
        self.pitch = 0.0
        self.playing = False
        self.start = 0.0            # wall time at which pos was 0 (at the current rate)
        self.paused_at = 0.0        # ms, while not playing
        self.master = False
        self.synced = True
        self.on_air = False
        self.fader = 0.0            # 0..1, the channel fader the sim DJ is moving
        self.bass = 1.0             # EQ low, 0..1
        self.load_count = 0

    def rate(self):
        return 1 + self.pitch / 100

    def pos(self, t=None):
        t = time.time() if t is None else t
        if not self.playing:
            return self.paused_at
        return max(0.0, (t - self.start) * 1000 * self.rate())

    def eff_bpm(self):
        return self.track["bpm"] * self.rate() if self.track else 0.0

    def beat(self, t=None):
        return int((self.pos(t) - self.track.get("offset_ms", 0)) // self.track["beat_ms"]) + 1 if self.track else 0

    def load(self, track):
        self.track = track
        self.load_count += 1
        self.ref = f"{self.n}{track['id']:03d}{self.load_count}"
        self.playing, self.paused_at, self.on_air, self.fader = False, 0.0, False, 0.0
        self.detail = track.get("detail_bytes") or wave_detail(track)

    def play_at(self, t_start, pos_ms=0.0):
        self.start = t_start - pos_ms / 1000 / self.rate()
        self.playing = True

    def stop(self):
        self.paused_at = self.pos()
        self.playing = False


DECKS = {1: Deck(1), 2: Deck(2)}
LOCK = threading.RLock()
LAST_BEAT = {1: 0.0, 2: 0.0}
BEAT_COUNT = {1: 0, 2: 0}
queue_i = [0]


def next_track():
    pool = REAL or TRACKS                         # the DJ's own tracks, when there are some
    t = pool[queue_i[0] % len(pool)]
    queue_i[0] += 1
    return t


def set_master(n):
    for d in DECKS.values():
        d.master = d.n == n


def match_pitch(d, bpm):
    d.pitch = (bpm / d.track["bpm"] - 1) * 100


def start_set():
    d1, d2 = DECKS[1], DECKS[2]
    d1.load(next_track())
    d2.load(next_track())
    match_pitch(d1, ARGS.bpm)
    match_pitch(d2, ARGS.bpm)
    set_master(1)
    # Start a few bars before the first build, so the show gets to a drop quickly.
    bar = max(1, d1.track["drops"][0][1] - 4)
    d1.play_at(time.time(), bar_ms(d1.track, bar))
    d1.fader, d1.on_air = 1.0, True


class AutoDJ:
    """Mixes the waiting deck in over the live deck's outro: starts it on the outro's first
    downbeat, brings its fader up over 8 bars, swaps the bass (and tempo master) at the midpoint,
    and fades the old deck out over the last 8 bars; then loads the next track on the old deck."""

    def __init__(self):
        self.mix = None             # (out deck, in deck, wall time the mix starts, bar length s)

    def tick(self, now):
        live = next((d for d in DECKS.values() if d.master and d.playing), None)
        if not live:
            return
        other = DECKS[2 if live.n == 1 else 1]
        if self.mix is None:
            if other.track is None or other.playing:
                return
            t, bar_s = live.track, 4 * live.track["beat_ms"] / 1000 / live.rate()
            outro_ms = bar_ms(t, t["outro_bar"])
            t_start = live.start + outro_ms / 1000 / live.rate()
            if now > t_start - 0.2 or now < t_start - 30:
                return
            match_pitch(other, live.eff_bpm())
            other.bass = 0.0
            self.mix = (live, other, t_start, bar_s)
            return
        out, inn, t0, bar_s = self.mix
        if now >= t0 and not inn.playing:
            inn.play_at(t0, inn.track.get("offset_ms", 0))   # its first downbeat on the outro's
            inn.on_air = True
        k = (now - t0) / bar_s                      # bars into the 16-bar mix
        if k < 0:
            return
        inn.fader = min(1.0, k / 8)
        if k >= 8 and not inn.master:
            inn.bass, out.bass = 1.0, 0.0
            set_master(inn.n)
        out.fader = 1.0 if k < 8 else max(0.0, 1 - (k - 8) / 8)
        if k >= 16:
            out.stop()
            out.on_air, out.fader, out.bass = False, 0.0, 1.0
            self.mix = None
            threading.Timer(3.0, lambda d=out: loader(d)).start()


def loader(d):
    with LOCK:
        if not d.playing:
            d.load(next_track())


AUTO = AutoDJ()


# ---------------------------------------------------------------- mixer model
def mixer_msg(now):
    chans, energies, kicks = {}, [], []
    bass_out = True
    for n, d in DECKS.items():
        if d.track and d.playing:
            bar = min(d.track["bars"], d.beat(now) // 4 + 1)
            typ = section_at(d.track, bar)[0]
            e = bar_energy(d.track, bar) * d.fader
            b = SECTION_BASS[typ] * d.bass * d.fader
            if b > 0.4:
                bass_out = False
                kicks.append(LAST_BEAT[n])
        else:
            e = 0.0
        energies.append(e)
        rms = -70.0 if e <= 0.002 else round(20 * math.log10(e) - 9 + random.uniform(-0.6, 0.6), 1)
        chans[f"ch{n}"] = {"rms_db": rms, "peak_db": round(rms + 6, 1), "peak_hold_db": round(rms + 7, 1), "active": rms > -70}
    total = sum(energies)
    mrms = -70.0 if total <= 0.002 else round(20 * math.log10(min(1.0, total)) - 8, 1)
    chans["master"] = {"rms_db": mrms, "peak_db": round(mrms + 6, 1), "peak_hold_db": round(mrms + 7, 1), "active": mrms > -70}
    share = [e / total for e in energies] if total > 0.002 else [0.0, 0.0]
    audio = {"low_db": round(mrms - (25 if bass_out else 4), 1), "mid_db": round(mrms - 8, 1), "high_db": round(mrms - 14, 1),
             "kick_ms": int(max(kicks) * 1000) if kicks else 0, "bass_out": bass_out and total > 0.002,
             "level": round(min(1.0, max(0.0, (mrms + 40) / 30)), 3)}
    return {"t": "mixer", "ts": int(now * 1000), "connected": True, "model": "DJM-450 (sim)", "channels": chans,
            "share": {"ch1": round(share[0], 3), "ch2": round(share[1], 3)}, "midi": {"count": 0, "recent": []},
            "audio": audio, "rec": {"on": False, "file": None, "secs": 0, "tracks": 0, "enabled": False, "error": None}}


MIXER = {"msg": {"connected": False}}


# ---------------------------------------------------------------- feed to showbrain
def feed_loop():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tgt = ("127.0.0.1", ARGS.feed)
    last_beat_no = {1: 0, 2: 0}
    next_status = 0.0
    while True:
        now = time.time()
        with LOCK:
            if not ARGS.no_auto:
                AUTO.tick(now)
            for n, d in DECKS.items():
                if not (d.track and d.playing):
                    continue
                b = d.beat(now)
                if b >= d.track["beats"]:                  # ran off the end
                    d.stop()
                    d.on_air = False
                    continue
                if b != last_beat_no[n]:
                    last_beat_no[n] = b
                    LAST_BEAT[n] = now
                    BEAT_COUNT[n] += 1
                    msg = {"t": "beat", "player": n, "bwb": (b - 1) % 4 + 1, "bpm": round(d.eff_bpm(), 3),
                           "nextBeatMs": int(d.track["beat_ms"] / d.rate()), "master": d.master, "ts": int(now * 1000)}
                    sock.sendto(json.dumps(msg).encode(), tgt)
            if now >= next_status:
                next_status = now + 0.05
                master = next((n for n, d in DECKS.items() if d.master), 0)
                players = [{"n": n, "playing": d.playing, "paused": not d.playing, "cued": bool(d.track) and not d.playing and d.paused_at == 0,
                            "looping": False, "master": d.master, "loaded": bool(d.track), "onAir": d.on_air,
                            "atEnd": bool(d.track) and d.beat(now) >= d.track["beats"],
                            "bpm": round(d.eff_bpm(), 3), "pitch": round(d.pitch, 3), "beat": d.beat(now) if d.track else 0,
                            "pos": int(d.pos(now)) if d.track else -1, "ref": d.ref,
                            "title": d.track["title"] if d.track else None, "key": d.track["key"] if d.track else None}
                           for n, d in DECKS.items()]
                sock.sendto(json.dumps({"t": "status", "ts": int(now * 1000), "master": master, "players": players}).encode(), tgt)
                MIXER["msg"] = mixer_msg(now)
                sock.sendto(json.dumps(MIXER["msg"]).encode(), tgt)
        time.sleep(0.004)


# ---------------------------------------------------------------- dashboard API
SHOW = {"json": "null", "at": 0.0}


def show_state():
    now = time.time()
    if now - SHOW["at"] > 0.2:
        SHOW["at"] = now
        try:
            with urllib.request.urlopen("http://127.0.0.1:8090/api/state", timeout=0.25) as r:
                SHOW["json"] = r.read().decode()
        except Exception:
            SHOW["json"] = "null"
    return SHOW["json"]


def player_json(d, now):
    t = d.track
    b = d.beat(now) if t else 0
    p = {"number": d.n, "name": "XDJ-700 (sim)", "address": f"127.0.0.{d.n}", "firmware": "sim",
         "status": {"trackLoaded": bool(t), "playing": d.playing, "paused": not d.playing, "cued": bool(t) and not d.playing,
                    "searching": False, "looping": False, "atEnd": False, "reverse": False, "onAir": d.on_air, "synced": d.synced,
                    "bpmSynced": False, "tempoMaster": d.master, "busy": d.playing,
                    "playState1": "PLAYING" if d.playing else "CUED", "playState2": "MOVING" if d.playing else "STOPPED", "playState3": "FORWARD_CDJ",
                    "trackBpm": t["bpm"] if t else 0, "pitchPct": round(d.pitch, 2), "effectiveBpm": round(d.eff_bpm(), 2),
                    "beatWithinBar": (b - 1) % 4 + 1 if b else 0, "beatNumber": b, "cueCountdown": "--",
                    "trackSourcePlayer": 1, "trackSourceSlot": "USB_SLOT", "trackType": "REKORDBOX", "rekordboxId": t["id"] if t else 0,
                    "trackNumber": 0, "syncNumber": 0, "usbLoaded": d.n == 1, "sdLoaded": False, "linkMediaAvailable": True,
                    "loopBeats": -1, "packetNumber": int(now * 5) % 100000},
         "beat": {"msSinceLast": int((now - LAST_BEAT[d.n]) * 1000) if LAST_BEAT[d.n] else -1, "count": BEAT_COUNT[d.n]},
         "hasArt": False}
    if t:
        p["position"] = {"ms": int(d.pos(now)), "definitive": True, "precise": True}
        cues = [{"hotCue": i + 1, "loop": False, "ms": int(bar_ms(t, b)), "loopMs": 0, "comment": "drop", "color": "#ff5a1f"}
                 for i, (b, bs) in enumerate(t["drops"])]
        p["track"] = {"title": t["title"], "artist": t["artist"], "album": "My tracks" if t.get("real") else "Synthetic Set", "genre": t["genre"], "key": t["key"],
                      "label": t["label"], "remixer": None, "originalArtist": None, "comment": "synthetic track (no hardware)",
                      "durationSec": t["dur"], "bpm": t["bpm"], "rating": t["rating"], "year": t["year"], "bitRate": 320,
                      "dateAdded": "2026-09-01", "artworkId": 0, "color": t["color"], "colorHex": None, "ref": d.ref, "cues": cues,
                      "audio": f"/api/audio/{t['id']}" if t.get("real") else None}
        p["sim"] = {"fader": round(d.fader, 3), "bass": round(d.bass, 3)}   # for the browser's audio (s5audio.js)
        p["grid"] = {"beats": t["beats"], "bar": (b - 1) // 4 + 1 if b else 0, "bars": t["bars"]}
        p["waveformKey"] = d.ref
        p["timelineKey"] = d.ref
    return p


def state_json():
    now = time.time()
    with LOCK:
        m = next((d for d in DECKS.values() if d.master), None)
        s = {"now": int(now * 1000), "uptimeSec": int(now - T0),
             "self": {"deviceNumber": 7, "name": "Sektor5 (sim)", "address": "127.0.0.1"},
             "master": ({"player": m.n, "name": "XDJ-700 (sim)", "bpm": round(m.eff_bpm(), 2)} if m else {"bpm": 0}),
             "devices": [{"number": n, "name": "XDJ-700 (sim)", "address": f"127.0.0.{n}", "mac": "00:00:00:00:00:0" + str(n), "seenMsAgo": 50} for n in DECKS]
                        + [{"number": 33, "name": "DJM-450 (sim)", "address": "127.0.0.33", "mac": "00:00:00:00:00:33", "seenMsAgo": 50}],
             "media": [{"player": 1, "slot": "USB_SLOT", "name": "SIM USB", "created": "2026-09-01", "tracks": len(TRACKS),
                        "playlists": 3, "totalBytes": 64 << 30, "freeBytes": 40 << 30, "type": "REKORDBOX"}],
             "players": [player_json(d, now) for d in DECKS.values()]}
        mixer = json.dumps(MIXER["msg"])
    body = json.dumps(s)[:-1]
    return f'{body}, "mixer": {mixer}, "show": {show_state()}, "tempo": {{"ok": true, "enabled": false}}}}'


def lib_track(t, n):
    return {"n": n, "id": t["id"], "title": t["title"], "artist": t["artist"], "album": "My tracks" if t.get("real") else "Synthetic Set", "genre": t["genre"],
            "label": t["label"], "key": t["key"], "color": t["color"], "bpm": t["bpm"], "dur": t["dur"], "rating": t["rating"],
            "year": t["year"], "bitrate": 320, "plays": 0, "added": "2026-09-01", "comment": "synthetic"}


PLAYLISTS = {1: ("Warm up", [t for t in TRACKS if t["bpm"] < 126]), 2: ("Peak time", [t for t in TRACKS if t["bpm"] >= 126]),
             3: ("Trance", [t for t in TRACKS if t["genre"] == "Trance"])}
if REAL:
    PLAYLISTS = {4: ("My tracks", REAL), **PLAYLISTS}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body, ct="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def deck_from_path(self):
        try:
            return DECKS.get(int(self.path.split("?")[0].rstrip("/").rsplit("/", 1)[1]))
        except ValueError:
            return None

    def do_GET(self):
        p = self.path.split("?")[0]
        q = dict(kv.split("=", 1) for kv in self.path.split("?", 1)[1].split("&") if "=" in kv) if "?" in self.path else {}
        if p in ("/", "/index.html", "/preview/", "/preview/index.html"):
            return self.send(200, (WEB / "index.html").read_bytes(), "text/html; charset=utf-8")
        if p.endswith("/s5auth.js") or p.endswith("/s5system.js") or p.endswith("/s5audio.js"):
            return self.send(200, (COMMON / p.rsplit("/", 1)[1]).read_bytes(), "text/javascript")
        if p == "/shell":                                # the sound player (the speaker), as deckdash serves it
            return self.send(200, (COMMON / "s5shell.html").read_bytes(), "text/html; charset=utf-8")
        if p.startswith("/preview/") and (ROOT / "projector" / "web" / p[9:]).is_file():   # stage page via the dashboard
            f = ROOT / "projector" / "web" / p[9:]
            return self.send(200, f.read_bytes(), {"html": "text/html; charset=utf-8", "js": "text/javascript"}.get(f.suffix[1:], "application/octet-stream"))
        if p == "/api/auth":
            return self.send(200, '{"enabled": false, "admin": true}')
        if p == "/api/system":
            return self.send(200, '{"ready": false}')
        if p == "/api/sim":                              # the sound player (/shell) leaves when this isn't on
            return self.send(200, json.dumps({"on": True, "available": True, "bpm": ARGS.bpm, "since": int(T0 * 1000),
                                              "djlink": False, "decks": 2, "uptime_s": int(time.time() - T0)}))
        if p == "/api/state":
            return self.send(200, state_json())
        if p == "/api/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            try:
                while True:
                    self.wfile.write(f"data: {state_json()}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(0.1)
            except Exception:
                return
        if p.startswith("/api/audio/"):                # a real track's audio, for the browser (s5audio.js)
            t = next((t for t in REAL if str(t["id"]) == p.rsplit("/", 1)[1]), None)
            return self.send(200, t["audio"].read_bytes(), "audio/mpeg") if t else self.send(404, "{}")
        if p.startswith("/api/timeline/"):
            d = self.deck_from_path()
            return self.send(200, json.dumps(timeline(d.track, d.ref))) if d and d.track else self.send(404, "{}")
        if p.startswith("/api/waveform/"):
            d = self.deck_from_path()
            return self.send(200, json.dumps(wave_overview(d.track))) if d and d.track else self.send(404, "{}")
        if p.startswith("/api/wavedetail/"):
            d = self.deck_from_path()
            return self.send(200, d.detail, "application/octet-stream") if d and d.track else self.send(404, "no detail", "text/plain")
        if p == "/api/library/tree":
            return self.send(200, json.dumps({"items": [{"id": k, "name": v[0], "folder": False, "count": len(v[1])} for k, v in PLAYLISTS.items()]}))
        if p == "/api/library/tracks":
            pl = int(q.get("playlist", "0") or 0)
            tr = TRACKS if pl not in PLAYLISTS else PLAYLISTS[pl][1]
            return self.send(200, json.dumps({"tracks": [lib_track(t, i + 1) for i, t in enumerate(tr)]}))
        if p == "/api/library":
            return self.send(200, json.dumps({"sources": [{"src": "1:USB_SLOT", "player": 1, "slot": "USB_SLOT", "name": "SIM USB",
                                                            "tracks": len(TRACKS), "playlists": len(PLAYLISTS), "ready": True}], "decks": [1, 2]}))
        if p == "/api/tempo":
            return self.send(200, '{"ok": true, "enabled": false}')
        self.send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        try:
            b = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            b = {}
        p = self.path.split("?")[0]
        if p.startswith("/api/auth"):
            return self.send(200, '{"ok": true, "enabled": false, "admin": true}')
        if p == "/api/tempo":
            return self.send(400, '{"ok": false, "error": "tempo master is off in the sim"}')
        if p != "/api/deck":
            return self.send(404, "{}")
        with LOCK:
            d = DECKS.get(int(b.get("deck", 0) or 0))
            if not d:
                return self.send(400, '{"ok": false, "error": "no such deck"}')
            a = b.get("action")
            other = DECKS[2 if d.n == 1 else 1]
            if a == "load":
                if d.playing and not b.get("force"):
                    return self.send(400, json.dumps({"ok": False, "error": f"deck {d.n} is playing; stop it first (or force)"}))
                t = next((t for t in TRACKS if t["id"] == int(b.get("id", 0))), None)
                if not t:
                    return self.send(400, '{"ok": false, "error": "no such track"}')
                if AUTO.mix and d in AUTO.mix[:2]:
                    AUTO.mix = None
                d.load(t)
                if other.track and d.synced:
                    match_pitch(d, other.eff_bpm() or ARGS.bpm)
            elif a == "play" and d.track and not d.playing:
                # Start on the next beat of the other deck, if it's playing (as SYNC would).
                now = time.time()
                if other.playing and other.track:
                    bl = other.track["beat_ms"] / 1000 / other.rate()
                    t_start = now + (bl - ((now - other.start - other.track.get("offset_ms", 0) / 1000 / other.rate()) % bl))
                else:
                    t_start = now
                d.play_at(t_start, d.paused_at or d.track.get("offset_ms", 0))
                d.on_air, d.fader = True, max(d.fader, 1.0 if not other.playing else d.fader)
                if not any(x.master for x in DECKS.values() if x.playing) or not other.playing:
                    set_master(d.n)
            elif a == "stop" and d.playing:
                d.stop()
                if AUTO.mix and d in AUTO.mix[:2]:
                    AUTO.mix = None
                if d.master and other.playing:
                    set_master(other.n)
            elif a == "sync_on":
                d.synced = True
                if other.track:
                    match_pitch(d, other.eff_bpm())
            elif a == "sync_off":
                d.synced = False
            elif a == "master":
                set_master(d.n)
            elif a == "seek" and d.track:
                ms = float(b.get("ms", 0))
                if d.playing:
                    d.play_at(time.time(), ms)
                else:
                    d.paused_at = ms
        self.send(200, '{"ok": true}')


T0 = time.time()
if __name__ == "__main__":
    with LOCK:
        start_set()
    threading.Thread(target=feed_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", ARGS.port), H)
    srv.daemon_threads = True
    print(f"fakerig: synthetic decks + mixer on :{ARGS.port}, feeding showbrain on UDP :{ARGS.feed}"
          f"{'' if not ARGS.no_auto else ' (auto-mix off)'}", flush=True)
    srv.serve_forever()
