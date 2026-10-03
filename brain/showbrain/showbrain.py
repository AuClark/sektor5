#!/usr/bin/env python3
"""Sektor5 show brain: read-ahead lighting driven by the decks.

Inputs:  deckdash feed (UDP 127.0.0.1:9100: beats + 20 Hz status) and
         per-track timelines (http://127.0.0.1:8080/api/timeline/N).
Outputs: DDP frames to every configured fixture (WLED tube, HUB75 panel...).
Control: Commander page + JSON API on :8090.

Scene flow (see docs/show-engine.md):
  IDLE -> INTRO/GROOVE <-> BREAKDOWN -> BUILD (-> HOLD while looping)
       -> PRE-DROP (blackout, last beat) -> DROP -> GROOVE ... -> OUTRO

    python3 brain/showbrain/showbrain.py [config.json]
"""
import bisect
import collections
import colorsys
import json
import math
import random
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

from ddp import DDPOutput
import s5auth
from dmx import UDMX
import looks

HERE = Path(__file__).parent
import envcfg
envcfg.load_env()
CONFIG = json.loads(envcfg.expand((Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "config.json").read_text()))


# ---------------------------------------------------------------- deck feed

class Decks:
    """Latest deck status and beat events from deckdash, plus track timelines."""

    def __init__(self):
        self.lock = threading.Lock()
        self.status = {}        # player -> dict (+ "_rx" local receive time)
        self.master = 0
        self.beats = {}         # player -> (rx_time, bwb, bpm)
        self.mixer = None       # latest DJM message from brain/mixer (+ "_rx")
        self.timelines = {}     # ref -> timeline dict
        self.fetching = set()
        threading.Thread(target=self._listen, daemon=True).start()

    def _listen(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", CONFIG.get("feed_port", 9100)))
        while True:
            msg = json.loads(s.recv(65536))
            now = time.time()
            with self.lock:
                if msg["t"] == "status":
                    self.master = msg.get("master", 0)
                    seen = set()
                    for p in msg["players"]:
                        p["_rx"] = now
                        self.status[p["n"]] = p
                        seen.add(p["n"])
                        ref = p.get("ref")
                        if ref and ref not in self.timelines and ref not in self.fetching:
                            self.fetching.add(ref)
                            threading.Thread(target=self._fetch, args=(p["n"], ref), daemon=True).start()
                    for n in list(self.status):
                        if n not in seen and now - self.status[n]["_rx"] > 3:
                            del self.status[n]
                elif msg["t"] == "beat":
                    self.beats[msg["player"]] = (now, msg["bwb"], msg["bpm"])
                elif msg["t"] == "mixer":
                    msg["_rx"] = now
                    self.mixer = msg

    def _fetch(self, player, ref):
        for _ in range(30):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:8080/api/timeline/{player}", timeout=3) as r:
                    t = json.loads(r.read())
                if t.get("ref") == ref:
                    with self.lock:
                        self.timelines[ref] = t
                        self.fetching.discard(ref)
                    log(f"timeline: {t.get('title')} - drops at bars {[d['bar'] for d in t.get('drops', [])]}")
                    return
            except Exception:
                pass
            time.sleep(1)
        with self.lock:
            self.fetching.discard(ref)

    def snapshot(self):
        with self.lock:
            return dict(self.status), self.master, dict(self.beats), self.timelines

    def mixer_state(self):
        with self.lock:
            m = self.mixer
        if not m or not m.get("connected") or time.time() - m["_rx"] > 1.0:
            return None
        return m


# ---------------------------------------------------------------- helpers

def log(msg):
    print(time.strftime("%X"), msg, flush=True)


def hsv(h, s=1.0, v=1.0):
    return colorsys.hsv_to_rgb(h % 1.0, max(0.0, min(1.0, s)), max(0.0, min(1.0, v)))


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def key_hue(key):
    """Camelot key like '9B' -> hue, so each track gets its own colour."""
    try:
        return ((int(key[:-1]) - 1) / 12 + (0.04 if key[-1] in "Bb" else 0)) % 1.0
    except (TypeError, ValueError):
        return 0.83


# ---------------------------------------------------------------- engine

class Engine:
    def __init__(self, decks):
        self.decks = decks
        self.mode = "auto"              # auto | manual | blackout
        self.follow = 0                 # 0 = auto, else player number
        self.lead_ms = CONFIG.get("lead_ms", 40)
        self.intensity = CONFIG.get("intensity", 0.8)
        self.hold = False
        self.strobe = False
        self.forced = None              # {"kind": "build"|"drop", "player", "start", "drop"} in beats
        # Performance layer (Commander pads), applied on top of the auto show.
        self.strobe_div = 2             # strobe flashes per beat; 0 = free-running 12 Hz
        self.blinder = False            # hold: everything full white
        self.black_hold = False         # hold: momentary blackout
        self.flash_t = 0.0              # tap: white hit decaying over about a beat
        self.look = None                # latched scene: INTRO | GROOVE | BREAKDOWN | DROP
        self.look_t = 0.0
        self.palette_mode = "auto"      # auto (track key) | lock | cycle | visuals
        self.palette_hue = 0.83
        self.visual = None              # the projected visual's main colour: {"hue", "sat", "t"} (/api/visual_colour)
        self.vis_hue = None             # where the lights' hue has glided to in visuals mode
        self.vis_t = 0.0
        self.speed = 1.0                # 0.5 half-time, 1, 2 double-time
        # Mixer reactions (DJM-450 via brain/mixer): bass kill, level, kicks, and mapped MIDI controls.
        self.mixer_react = CONFIG.get("mixer", {}).get("react", True)
        self.bass_was_out = False
        self.fx_active = False          # Beat FX on (needs mixer.midi.fx_on mapped)
        self.filters = {}               # mixer channel -> filter offset -1..1 (needs mixer.midi.chN_filter)
        self.midi_t = 0.0               # newest MIDI message already handled
        self.mix = {}                   # what the mixer is doing now, for the Commander
        # The last few output frames (time, {fixture: preview}), so a viewer polling at 25 Hz still
        # gets every 50 fps frame and can play them back at their real timing (the Stage view).
        self.frames = collections.deque(maxlen=4)
        self.fixture_ctl = {}           # fixture name -> {"on": bool, "level": 0..1}
        # Tap clock: drives the lights when no deck is playing (looks or forced events only).
        self.tap_bpm = 128.0
        self.tap_anchor = self.tap_first = time.time()
        self.taps = []
        self.overrides_path = HERE / "overrides.json"
        try:
            self.overrides = json.loads(self.overrides_path.read_text())
        except (OSError, ValueError):
            self.overrides = {}         # title -> {"skip": [beats], "add": [beats]}
        self.state = {}
        self.sparks = []
        self.last_live = None
        self.frozen_progress = 0.0
        self.playing_since = {}         # player -> time it started playing (for hand-over)
        self.share_smooth = {}          # player -> smoothed share of the mix (from the DJM)
        self.dominant_since = {}        # player -> time its share went above the take-over threshold
        self.live_reason = ""
        self.outro_since = None
        self.last_beat_seen = {}        # player -> rx time of the last beat packet we measured
        self.phase_err = []             # recent (model - packet) errors in ms, for the diagnostic

    # --- position model ------------------------------------------------
    def position(self, p, t):
        """Track position in ms at time t for status p (interpolated while playing)."""
        pos = p.get("pos", -1)
        if pos is None or pos < 0:
            return None
        if p.get("playing"):
            pos += (t - p["_rx"]) * 1000 * (1 + p.get("pitch", 0) / 100)
        return pos

    @staticmethod
    def beat_at(tl, pos):
        """Fractional beat number (1-based) at track position pos, using the beat grid."""
        bm = tl["beatMs"]
        i = bisect.bisect_right(bm, pos)
        if i == 0:
            return 1.0 + (pos - bm[0]) / max(1, bm[1] - bm[0])
        if i >= len(bm):
            return float(len(bm))
        return i + (pos - bm[i - 1]) / max(1, bm[i] - bm[i - 1])

    @staticmethod
    def bar_of(tl, beat):
        fb = tl["barFirstBeat"]
        i = bisect.bisect_right(fb, int(beat))
        bar = max(1, i)
        return bar, int(beat) - fb[bar - 1] + 1    # (bar, beat within bar 1..)

    def section_of(self, p, t, timelines):
        """(section type, beat) for a deck right now, or (None, None) without a timeline."""
        tl = timelines.get(p.get("ref"))
        pos = self.position(p, t)
        if not tl or pos is None:
            return None, None
        beat = self.beat_at(tl, pos)
        sec = next((s for s in tl["sections"] if s["startBeat"] <= beat <= s["endBeat"] + 0.999), None)
        return (sec["type"] if sec else None), beat

    def mixer_pick(self, status, t):
        """Live deck from the DJM's post-fader levels. Returns a player, None (nothing audible),
        or False (no mixer data: fall back to the deck-state rules)."""
        m = self.decks.mixer_state()
        if m is None:
            return False
        cfg = CONFIG.get("mixer", {})
        chmap = {int(k): v for k, v in cfg.get("channels", {"1": 1, "2": 2}).items()}   # mixer ch -> player
        take, hold_s, alpha = cfg.get("takeover_share", 0.7), cfg.get("takeover_s", 2.0), cfg.get("smoothing", 0.15)
        silent = cfg.get("silent_db", -60.0)
        shares = {}
        for ch, player in chmap.items():
            raw = m.get("share", {}).get(f"ch{ch}", 0.0)
            if m.get("channels", {}).get(f"ch{ch}", {}).get("rms_db", -200) < silent:
                raw = 0.0
            prev = self.share_smooth.get(player, raw)
            shares[player] = prev + alpha * (raw - prev)
        self.share_smooth = shares
        if all(v < 0.05 for v in shares.values()):
            self.live_reason = "mixer: nothing audible"
            return self.last_live if self.last_live in status else None
        for player, v in shares.items():
            if v >= take:
                self.dominant_since.setdefault(player, t)
            else:
                self.dominant_since.pop(player, None)
        cur = self.last_live
        for player, since in self.dominant_since.items():
            if player != cur and player in status and t - since >= hold_s:
                self.live_reason = f"mixer: deck {player} holds {shares[player]:.0%} of the mix"
                return player
        if cur in shares and cur in status:
            self.live_reason = f"mixer: staying on deck {cur} ({shares[cur]:.0%})"
            return cur
        best = max(shares, key=shares.get)
        self.live_reason = f"mixer: deck {best} loudest"
        return best if best in status else None

    def live_deck(self, status, master, timelines=None, t=None):
        """Which deck the lights follow. Sticky: cueing or previewing another deck never steals it.

        Priority: manual follow > mixer on-air flags (if a DJM is on the link) > stay on the current
        deck while it plays > hand over when the current deck stops/ends/sits in its outro, or when
        the incoming deck hits a drop while the outgoing one is already in its outro.
        """
        timelines = timelines or {}
        t = t or time.time()
        if self.follow and self.follow in status:
            self.live_reason = "locked in Commander"
            return self.follow
        pick = self.mixer_pick(status, t)
        if pick is not False:
            return pick
        playing = {n: p for n, p in status.items() if p.get("playing")}
        on_air = [n for n, p in playing.items() if p.get("onAir")]
        self.live_reason = "deck state (no mixer data)"
        if on_air:                                   # real fader data wins when we have it
            cur = self.last_live if self.last_live in on_air else on_air[0]
            return cur
        cur = self.last_live
        if cur not in playing or status[cur].get("atEnd"):
            # Current deck stopped: take the deck that has been playing longest.
            if not playing:
                return None
            self.playing_since = {n: v for n, v in self.playing_since.items() if n in playing}
            for n in playing:
                self.playing_since.setdefault(n, t)
            return min(playing, key=lambda n: self.playing_since[n])
        for n in playing:
            self.playing_since.setdefault(n, t)
        for n in list(self.playing_since):
            if n not in playing:
                del self.playing_since[n]
        others = [n for n in playing if n != cur]
        if not others:
            return cur
        sec_cur, _ = self.section_of(status[cur], t, timelines)
        if sec_cur == "outro":
            self.outro_since = self.outro_since or t
        else:
            self.outro_since = None
        for n in others:
            sec_in, _ = self.section_of(status[n], t, timelines)
            # Incoming deck drops while outgoing is winding down: follow the drop.
            if sec_in == "drop" and sec_cur in ("outro", None):
                return n
            # Outgoing has been in its outro for 16+ s with the new deck running for 30+ s: mix is done.
            if self.outro_since and t - self.outro_since > 16 and t - self.playing_since.get(n, t) > 30:
                return n
        return cur

    # --- scene decision --------------------------------------------------
    def decide(self, t):
        status, master, beats, timelines = self.decks.snapshot()
        live = self.live_deck(status, master, timelines, t)
        ctx = {"t": t, "live": live, "scene": "IDLE", "hue": 0.83, "frac": 0.0, "bwb": 1, "bar": 0,
               "beat": 0.0, "progress": 0.0, "since_drop": 0.0, "beats_to_drop": None, "title": None,
               "bpm": 0.0, "section": None, "next_drop_bar": None,
               "section_progress": 0.0, "energy": 0.5}
        if live is None:
            self.last_live = None
            if self.look or (self.forced and self.forced["player"] is None):
                return self._free(ctx, t)
            return ctx
        if live != self.last_live:
            if self.last_live is not None:
                log(f"live deck -> {live}")
            self.last_live = live
            self.forced = None
        p = status[live]
        ctx.update(title=p.get("title"), bpm=p.get("bpm", 0), hue=key_hue(p.get("key")))
        tl = timelines.get(p.get("ref"))
        pos = self.position(p, t + self.lead_ms / 1000)

        if tl is None or pos is None:
            # No timeline yet: follow beat events only.
            b = beats.get(live)
            if b:
                period = 60 / max(1, b[2])
                ctx["frac"] = ((t + self.lead_ms / 1000 - b[0]) / period) % 1.0
                ctx["bwb"] = b[1]
            ctx["scene"] = "GROOVE" if p.get("playing") else "PAUSED"
            return ctx

        beat = self.beat_at(tl, pos)
        bar, bwb = self.bar_of(tl, beat)
        ctx.update(beat=beat, frac=beat % 1.0, bar=bar, bwb=bwb)

        # Diagnostic: at each real beat packet, where did the position model think we were?
        b = beats.get(live)
        if b and p.get("playing") and b[0] != self.last_beat_seen.get(live):
            self.last_beat_seen[live] = b[0]
            mpos = self.position(p, b[0])
            if mpos is not None:
                ph = self.beat_at(tl, mpos) % 1.0
                err = (ph if ph < 0.5 else ph - 1.0) * 60000 / max(1.0, b[2])
                self.phase_err = (self.phase_err + [err])[-32:]
        cal = self.overrides.get("_calibration", [])
        if cal:
            ds = sorted(c["delta_beats"] for c in cal)
            ctx["calibration"] = {"marks": len(ds), "median_delta_beats": ds[len(ds) // 2]}
        if self.phase_err:
            srt = sorted(self.phase_err)
            ctx["phase_err_ms"] = round(srt[len(srt) // 2], 1)
        if not p.get("playing"):
            ctx["scene"] = "PAUSED"
            return ctx

        section = next((s for s in tl["sections"] if s["startBeat"] <= beat <= s["endBeat"] + 0.999), None)
        ctx["section"] = section["type"] if section else None
        if section:
            span = max(1.0, section["endBeat"] + 1 - section["startBeat"])
            ctx["section_progress"] = max(0.0, min(1.0, (beat - section["startBeat"]) / span))
        en = tl.get("energy") or []
        ctx["energy"] = en[bar - 1] / 100 if 0 < bar <= len(en) else 0.5
        drops = self.drops_for(p.get("title"), tl)
        ctx["drops"] = [{"bar": d["bar"], "manual": bool(d.get("manual"))} for d in drops]

        # Forced events from the Commander take priority.
        if self.forced and self.forced["player"] == live:
            f = self.forced
            if f["kind"] == "build" and beat < f["drop"]:
                return self._build(ctx, beat, f["start"], f["drop"], p)
            if beat - f["drop"] < CONFIG.get("drop_bars", 16) * 4:
                return self._drop(ctx, beat - f["drop"])
            self.forced = None

        if self.mode == "manual":
            ctx["scene"] = "GROOVE"
            return ctx

        nxt = next((d for d in drops if d["beat"] > beat - CONFIG.get("drop_bars", 16) * 4), None)
        if nxt:
            ctx["next_drop_bar"] = nxt["bar"]
            if beat < nxt["beat"]:
                ctx["beats_to_drop"] = nxt["beat"] - beat
            if nxt["buildStartBeat"] <= beat < nxt["beat"]:
                return self._build(ctx, beat, nxt["buildStartBeat"], nxt["beat"], p)
            if nxt["beat"] <= beat:
                return self._drop(ctx, beat - nxt["beat"])
        ctx["scene"] = {"intro": "INTRO", "breakdown": "BREAKDOWN", "outro": "OUTRO"}.get(ctx["section"], "GROOVE")
        return ctx

    def drops_for(self, title, tl):
        """Timeline drops with this track's saved overrides applied."""
        ov = self.overrides.get(title or "", {}) if title != "_calibration" else {}
        skip = set(ov.get("skip", []))
        drops = [d for d in tl["drops"] if d["beat"] not in skip]
        fb = tl["barFirstBeat"]
        for beat in ov.get("add", []):
            bar = max(1, bisect.bisect_right(fb, beat))
            start_bar = max(1, bar - 8)
            drops.append({"bar": bar, "beat": beat, "ms": 0, "confidence": 1.0, "cue": False, "manual": True,
                          "buildStartBar": start_bar, "buildStartBeat": fb[start_bar - 1]})
        return sorted(drops, key=lambda d: d["beat"])

    def save_overrides(self):
        self.overrides_path.write_text(json.dumps(self.overrides, indent=1))

    def _build(self, ctx, beat, start, drop, p):
        ctx["beats_to_drop"] = drop - beat
        if drop - beat <= 1.0:
            ctx["scene"] = "PREDROP"
            return ctx
        progress = (beat - start) / max(1.0, (drop - 1) - start)
        if p.get("looping") or self.hold:
            ctx["scene"] = "HOLD"
            progress = self.frozen_progress
        else:
            self.frozen_progress = progress
            ctx["scene"] = "BUILD"
        ctx["progress"] = max(0.0, min(1.0, progress))
        return ctx

    def _drop(self, ctx, since):
        ctx["scene"] = "DROP"
        ctx["since_drop"] = since
        return ctx

    # --- tap clock (no deck playing) --------------------------------------
    def free_beat(self, t):
        """1-based fractional beat on the tap clock; beat 1 is the anchor (a downbeat)."""
        return (t - self.tap_anchor) * self.tap_bpm / 60 + 1

    def _free(self, ctx, t):
        beat = self.free_beat(t + self.lead_ms / 1000)
        ctx.update(scene="GROOVE", beat=beat, frac=beat % 1.0, bar=int((beat - 1) // 4) + 1,
                   bwb=int(beat - 1) % 4 + 1, bpm=self.tap_bpm, title="Tap clock", free=True,
                   energy=0.6, section_progress=0.5)
        f = self.forced
        if f and f["player"] is None:
            if f["kind"] == "build" and beat < f["drop"]:
                return self._build(ctx, beat, f["start"], f["drop"], {})
            if beat - f["drop"] < CONFIG.get("drop_bars", 16) * 4:
                return self._drop(ctx, beat - f["drop"])
            self.forced = None
        return ctx

    # --- performance layer -------------------------------------------------
    def shape(self, ctx, t):
        """Apply the Commander's latched look, speed and palette to the auto show's ctx."""
        if self.look and not self.forced:
            ctx["scene"] = self.look
            if self.look == "DROP":
                ctx["since_drop"] = (t - self.look_t) * max(60.0, ctx.get("bpm") or self.tap_bpm) / 60
        if self.speed != 1.0 and ctx["bar"] > 0:
            b = (ctx["beat"] - 1) * self.speed + 1
            ctx.update(beat=b, frac=b % 1.0, bwb=int(b - 1) % 4 + 1)
        if self.palette_mode == "lock":
            ctx["hue"] = self.palette_hue
        elif self.palette_mode == "cycle":
            step = (ctx["bar"] - 1) // 4 if ctx["bar"] > 0 else int(t / 8)
            ctx["hue"] = (ctx["hue"] + 0.125 * step) % 1.0
        elif self.palette_mode == "visuals":
            ctx["hue"] = self.visual_hue(ctx["hue"], t)
        return ctx

    def visual_hue(self, key_hue, t):
        """The projected visual's main colour, glided to (about half a second, the short way round the
        colour wheel) so the lights follow the picture without flicking. No reading for 5 s (the
        projector page closed, or a dark or grey picture): glide back to the track's key colour."""
        v = self.visual
        target = v["hue"] if v and t - v["t"] < 5.0 else key_hue
        dt = min(0.25, max(0.0, t - self.vis_t))
        self.vis_t = t
        if self.vis_hue is None:
            self.vis_hue = target
        d = (target - self.vis_hue + 0.5) % 1.0 - 0.5
        self.vis_hue = (self.vis_hue + d * (1 - math.exp(-dt / 0.5))) % 1.0
        return self.vis_hue

    def react(self, ctx, t):
        """Layer what the mixer is doing on top of the show: runs after shape(), before output_fx()."""
        m = self.decks.mixer_state()
        audio = (m or {}).get("audio")
        self.mix = {"react": self.mixer_react, "connected": bool(m), "bass_out": False,
                    "fx": self.fx_active, "filter": 0.0, "level": None}
        if not m:
            return ctx
        self._midi(m)
        if not self.mixer_react or not audio or ctx["scene"] in ("IDLE", "PREDROP"):
            self.bass_was_out = bool(audio and audio.get("bass_out"))
            return ctx
        cfg = CONFIG.get("mixer", {})
        # Bass killed (EQ, filter or fader): the sparse breakdown look, and a hit when it comes back.
        out = bool(audio.get("bass_out"))
        if out and ctx["scene"] in ("GROOVE", "DROP", "INTRO", "OUTRO"):
            ctx["scene"] = "BREAKDOWN"
            ctx.setdefault("section_progress", 0.5)
        if self.bass_was_out and not out and ctx["scene"] not in ("BUILD", "HOLD"):
            self.flash_t = t
        self.bass_was_out = out
        # No beat grid for this track: let the kicks in the mix drive the beat.
        kick = audio.get("kick_ms") or 0
        if ctx["bar"] == 0 and kick and t * 1000 - kick < 2000:
            period = 60 / max(60.0, ctx.get("bpm") or 120.0)
            ctx["frac"] = min(0.999, (t - kick / 1000) / period)
        # Filter on the live deck's channel: sweep the colour with it.
        chmap = {v: int(k) for k, v in cfg.get("channels", {"1": 1, "2": 2}).items()}     # player -> mixer ch
        f = self.filters.get(chmap.get(ctx.get("live")), 0.0)
        if abs(f) > 0.05:
            ctx["hue"] = (ctx["hue"] + 0.3 * f) % 1.0
        self.mix.update(bass_out=out, filter=round(f, 2), level=audio.get("level"))
        return ctx

    def _midi(self, m):
        """Mapped DJM controls from the MIDI the mixer reports (config mixer.midi: name -> "B0 06")."""
        mapping = {v.upper(): k for k, v in CONFIG.get("mixer", {}).get("midi", {}).items() if v}
        newest = self.midi_t
        for msg in (m.get("midi") or {}).get("recent", []):
            if msg["t"] <= self.midi_t:
                continue
            newest = max(newest, msg["t"])
            parts = msg["hex"].upper().split()
            name = mapping.get(" ".join(parts[:2])) if len(parts) == 3 else None
            if not name:
                continue
            v = int(parts[2], 16)
            if name == "fx_on":
                self.fx_active = v >= 64
            elif name.endswith("_filter") and name[:2] == "ch":
                self.filters[int(name[2:name.index("_")])] = (v - 64) / 63.0
        self.midi_t = newest

    def output_fx(self, ctx, t):
        """Post-look effects every fixture applies: strobe, white (blinder / flash), blackout."""
        strobe = None
        if self.strobe or (self.mixer_react and self.fx_active):
            if self.strobe_div:
                strobe = ((ctx["frac"] * self.strobe_div) % 1.0) < 0.5
            else:
                strobe = (t * 12) % 1.0 < 0.5
        white = 1.0 if self.blinder else (math.exp(-(t - self.flash_t) * 4) if t - self.flash_t < 1.5 else 0.0)
        intensity = self.intensity
        level = self.mix.get("level")
        if self.mixer_react and level is not None and ctx["scene"] not in ("IDLE", "PREDROP"):
            intensity *= 0.6 + 0.4 * level            # faders down, lights down
        return {"intensity": intensity, "strobe": strobe, "white": white, "black": self.black_hold}

    # --- commands --------------------------------------------------------
    def command(self, c):
        cmd = c.get("cmd")
        status, master, _, timelines = self.decks.snapshot()
        live = self.last_live
        t = time.time()
        if cmd == "mode":
            self.mode = c.get("value", "auto")
        elif cmd == "follow":
            self.follow = int(c.get("value", 0))
        elif cmd == "lead_ms":
            self.lead_ms = int(c.get("value", 40))
        elif cmd == "intensity":
            self.intensity = float(c.get("value", 0.8))
        elif cmd == "hold":
            self.hold = not self.hold
        elif cmd == "strobe":
            self.strobe = bool(c.get("value", not self.strobe))
        elif cmd == "strobe_div":
            self.strobe_div = int(c.get("value", 2))
        elif cmd == "blinder":
            self.blinder = bool(c.get("value", False))
        elif cmd == "black_hold":
            self.black_hold = bool(c.get("value", False))
        elif cmd == "mixer_react":
            self.mixer_react = bool(c.get("value", not self.mixer_react))
        elif cmd == "flash":
            self.flash_t = t
        elif cmd == "look":
            v = c.get("value")
            if v not in (None, "AUTO", "INTRO", "GROOVE", "BREAKDOWN", "DROP"):
                return {"ok": False, "error": f"unknown look {v}"}
            self.look = None if v in (None, "AUTO") else v
            self.look_t = t
        elif cmd == "palette":
            v = c.get("value") or {}
            if v.get("mode") in ("auto", "lock", "cycle", "visuals"):
                self.palette_mode = v["mode"]
            if v.get("hue") is not None:
                self.palette_hue = float(v["hue"]) % 1.0
        elif cmd == "speed":
            self.speed = float(c.get("value", 1.0)) if float(c.get("value", 1.0)) in (0.5, 1.0, 2.0) else 1.0
        elif cmd == "fixture":
            v = c.get("value") or {}
            ctl = self.fixture_ctl.get(v.get("name"))
            if ctl is None:
                return {"ok": False, "error": "unknown fixture"}
            if "on" in v:
                ctl["on"] = bool(v["on"])
            if "level" in v:
                ctl["level"] = max(0.0, min(1.0, float(v["level"])))
        elif cmd == "tap":
            # Taps more than 2 s apart start a new sequence; the first tap is the downbeat.
            if not self.taps or t - self.taps[-1] >= 2:
                self.taps, self.tap_first = [], t
            self.taps = self.taps[-7:] + [t]
            if len(self.taps) >= 2:
                self.tap_bpm = max(60.0, min(200.0, 60 * (len(self.taps) - 1) / (self.taps[-1] - self.taps[0])))
                # Phase-lock to the latest tap, keeping the first tap of the sequence as beat 1 of a bar.
                period = 60 / self.tap_bpm
                self.tap_anchor = t - round((t - self.tap_first) / period) * period
        elif cmd == "tap_bpm":
            self.tap_bpm = max(60.0, min(200.0, float(c.get("value", 128))))
        elif cmd == "tap_sync":
            self.tap_anchor = t
        elif cmd in ("drop_now", "build") and not live:
            # No deck playing: run the event on the tap clock.
            beat = self.free_beat(t)
            if cmd == "drop_now":
                self.forced = {"kind": "drop", "player": None, "start": beat, "drop": beat}
            else:
                bar = int((beat - 1) // 4) + 1
                self.forced = {"kind": "build", "player": None, "start": beat,
                               "drop": (bar + int(c.get("value", 4)) - 1) * 4 + 1}
        elif cmd in ("drop_now", "build") and live:
            p = status[live]
            tl = timelines.get(p.get("ref"))
            pos = self.position(p, t)
            if tl is None or pos is None:
                return {"ok": False, "error": "no timeline for live deck"}
            beat = self.beat_at(tl, pos)
            if cmd == "drop_now":
                self.forced = {"kind": "drop", "player": live, "start": beat, "drop": beat}
            else:
                bars = int(c.get("value", 4))
                bar, _ = self.bar_of(tl, beat)
                fb = tl["barFirstBeat"]
                drop = fb[min(len(fb) - 1, bar + bars - 1)]
                self.forced = {"kind": "build", "player": live, "start": beat, "drop": drop}
        elif cmd in ("skip_drop", "mark_drop") and live:
            p = status[live]
            tl = timelines.get(p.get("ref"))
            pos = self.position(p, t)
            if not tl or pos is None:
                return {"ok": False, "error": "no timeline for live deck"}
            beat = self.beat_at(tl, pos)
            ov = self.overrides.setdefault(p.get("title") or "", {"skip": [], "add": []})
            if cmd == "skip_drop":
                nxt = next((d for d in self.drops_for(p.get("title"), tl) if d["beat"] > beat), None)
                if not nxt:
                    return {"ok": False, "error": "no drop ahead"}
                if nxt.get("manual"):
                    ov["add"].remove(nxt["beat"])
                else:
                    ov["skip"].append(nxt["beat"])
            else:
                # Snap to the nearest bar line.
                fb = tl["barFirstBeat"]
                i = bisect.bisect_left(fb, beat)
                cands = [fb[k] for k in (i - 1, i) if 0 <= k < len(fb)]
                marked = min(cands, key=lambda b: abs(b - beat))
                # Calibration: how far was the nearest automatic prediction from the real drop?
                auto = [d for d in tl["drops"] if abs(d["beat"] - marked) <= 64]
                if auto:
                    near = min(auto, key=lambda d: abs(d["beat"] - marked))
                    delta = near["beat"] - marked          # + = predicted late
                    cal = self.overrides.setdefault("_calibration", [])
                    cal.append({"title": p.get("title"), "predicted": near["beat"], "actual": marked, "delta_beats": delta})
                    log(f"calibration: predicted beat {near['beat']} vs actual {marked} ({delta:+d} beats)")
                    if near["beat"] not in ov["skip"]:
                        ov["skip"].append(near["beat"])     # replace the wrong prediction with the mark
                ov["add"].append(marked)
            self.save_overrides()
        elif cmd == "clear":
            self.forced, self.hold, self.strobe, self.mode = None, False, False, "auto"
            self.blinder = self.black_hold = False
            self.look, self.palette_mode, self.speed = None, "auto", 1.0
        log(f"command {c}")
        return {"ok": True}


# ---------------------------------------------------------------- outputs

UDMX_DEVICES = {}      # one UDMX per process, shared by every DMX fixture


class Fixture:
    def __init__(self, cfg, index=0, group=1):
        self.cfg = cfg
        self.kind = cfg["kind"]             # strip | panel | pyramid | dmx_par
        self.role = dict(cfg.get("role", {}), index=index, group=group)
        self.state = {}
        self.delay = cfg.get("delay_ms", 0) / 1000.0
        self.queue = []                      # (time, frame) for delay compensation
        self.name = cfg.get("name") or f"{self.kind}{index}"
        self.preview = []
        if self.kind == "dmx_par":
            self.dmx = UDMX_DEVICES.setdefault("udmx", UDMX())
            self.addr = cfg.get("address", 1)
            self.chans = cfg["channels"]    # name -> offset (1-based within the fixture)
            self.extra = set(cfg.get("verified_extra", []))   # e.g. ["w", "uv"] once tested
            self.out = None
            return
        self.w = cfg.get("width", 128)
        self.h = cfg.get("height", 16)
        self.legs = cfg.get("leds_per_leg", 60)       # pyramid: four legs of this many, then the laser
        # A "mirrored" pyramid has all four legs on one data line (an SP901E's four copies): it gets
        # looks for identical legs and is sent one leg (no laser). "from_apex": its strips are fed
        # from the top, so each leg is sent apex first. The preview stays four legs, foot first.
        # "diagonals": two data lines (an SP901E's DAT 1 and DAT 2), front-left + back-right on the
        # first, front-right + back-left on the second: sent as two streams of one leg each, to
        # "ports" (default 4048 and 4049) on the host. No laser.
        self.mirrored = self.kind == "pyramid" and cfg.get("wiring") == "mirrored"
        self.diagonals = self.kind == "pyramid" and cfg.get("wiring") == "diagonals"
        self.role["mirrored"], self.role["diagonals"] = self.mirrored, self.diagonals
        count = (cfg["leds"] if self.kind == "strip" else (self.legs if self.mirrored or self.diagonals else 4 * self.legs + 1)
                 if self.kind == "pyramid" else self.w * self.h)
        ports = cfg.get("ports") or [4048, 4049]
        self.out = DDPOutput(cfg["host"], count, port=ports[0], brightness=cfg.get("brightness", 0.6), name=cfg.get("name"))
        self.out2 = (DDPOutput(cfg["host"], count, port=ports[1], brightness=cfg.get("brightness", 0.6), name=cfg.get("name"))
                     if self.diagonals else None)

    @property
    def always(self):
        """DMX holds its last value, so keep rendering it even when the show is idle."""
        return self.kind == "dmx_par"

    def render(self, ctx, fx, ctl, preview=False):
        """Render this fixture; a failing look blacks out this fixture only, never the whole show."""
        try:
            return self._render(ctx, fx, ctl, preview)
        except Exception as e:                      # noqa: BLE001 - one bad look must not stop the show
            key = f"{type(e).__name__}: {e}"
            if key != getattr(self, "_last_err", None):
                self._last_err = key
                log(f"fixture {self.cfg.get('name')}: {key} (blacked out, show continues)")
            self.state.clear()
            try:
                if self.kind == "dmx_par":
                    self._send([0] * max(self.chans.values()))
                elif getattr(self, "out", None) is not None:
                    import numpy as np
                    self.out.send_array(np.zeros((self.out.count, 3), np.float32))
            except Exception:
                pass
            return None

    def _render(self, ctx, fx, ctl, preview=False):
        """fx: Engine.output_fx(); ctl: this fixture's {"on", "level"} from the Commander."""
        level = 0.0 if (fx["black"] or not ctl["on"]) else fx["intensity"] * ctl["level"]
        if self.kind == "dmx_par":
            frame = self._par_frame(ctx, level, fx)
        else:
            laser = None
            if self.kind == "strip":
                px = looks.strip(ctx, self.cfg["leds"], self.role, self.state)
                if self.cfg.get("reverse"):
                    px = px[::-1]
            elif self.kind == "pyramid":
                px = looks.pyramid(ctx, self.legs, self.role, self.state)
                laser, px = px[-1, 0] > 0.5, px[:-1]
            else:
                px = looks.panel(ctx, self.w, self.h, self.role, self.state)
            if fx["strobe"] is not None:
                px = px * 0 + (1.0 if fx["strobe"] else 0.0)
            if fx["white"] > 0:
                px = px + (1.0 - px) * fx["white"]
            frame = px * level
            if laser is not None:
                # The laser is on/off (WLED's On/Off output): full on whatever the brightness, off in a blackout.
                on = laser and level > 0
                frame = np.vstack([frame, np.full((1, 3), (1.0 / max(0.01, self.out.brightness)) if on else 0.0, np.float32)])
        if preview:
            self.preview = self._preview(frame)
        # Delay compensation: fast outputs (USB DMX) wait so they land with the Wi-Fi fixtures.
        now = time.time()
        if self.delay > 0:
            self.queue.append((now, frame))
            while len(self.queue) > 1 and self.queue[1][0] <= now - self.delay:
                self.queue.pop(0)
            if self.queue[0][0] > now - self.delay:
                return
            frame = self.queue[0][1]
        self._send(frame)

    # Light each DMX emitter adds, as linear RGB (roughly what the eye sees from the par can's LEDs).
    EMITTERS = {"r": (1, 0, 0), "g": (0, 1, 0), "b": (0, 0, 1), "w": (1, 0.93, 0.82), "a": (1, 0.55, 0.04), "uv": (0.3, 0.02, 0.85)}

    def _preview(self, frame):
        """What this fixture is actually being sent, as hex: linear drive levels 0..255 per LED
        (after the fixture's brightness, before the delay). Strips: every LED (max 300); the
        panel: 40 column averages; the par can: its emitters mixed into one colour."""
        if self.kind == "dmx_par":
            c = {name: frame[off - 1] / 255 for name, off in self.chans.items()}
            if "dimmer" in c:
                d = c["dimmer"]
                c = {k: v * d for k, v in c.items()}
            rgb = np.zeros(3)
            for name, tint in self.EMITTERS.items():
                rgb += np.array(tint) * c.get(name, 0.0)
            peak = rgb.max()
            if peak > 1:                            # keep the hue, don't clip channels
                rgb /= peak
            return ["#%02x%02x%02x" % tuple(int(round(x * 255)) for x in rgb)]
        a = frame if self.kind in ("strip", "pyramid") else frame.mean(axis=0)
        n = len(a) if self.kind == "pyramid" else min(len(a), 300 if self.kind == "strip" else 40)   # a pyramid's map must stay whole
        a = a[np.linspace(0, len(a) - 1, n).astype(int)] * self.out.brightness
        return ["#%02x%02x%02x" % tuple(px) for px in (np.clip(a, 0, 1) * 255).round().astype(int).tolist()]

    def _par_frame(self, ctx, intensity, fx):
        v = looks.par(ctx, self.role, self.state)
        if fx["strobe"] is not None:
            on = 1.0 if fx["strobe"] else 0.0
            v = dict(dimmer=1.0, r=on, g=on, b=on, w=on if "w" in self.extra else 0.0, a=0.0, uv=0.0)
        if fx["white"] > 0:
            v = {k: (x + (1.0 - x) * fx["white"] if k in ("r", "g", "b", "w") else x) for k, x in v.items()}
        k = intensity * self.cfg.get("brightness", 1.0)
        n = max(self.chans.values())
        ch = [0] * n
        for name, off in self.chans.items():
            if name == "dimmer":
                ch[off - 1] = int(255 * v["dimmer"])
            elif name in ("r", "g", "b"):
                ch[off - 1] = int(255 * min(1.0, v[name] * k))
            elif name in ("w", "a", "uv"):
                ch[off - 1] = int(255 * min(1.0, v[name] * k)) if name in self.extra else 0
            else:
                ch[off - 1] = 0             # strobe / program / speed: never let the fixture run its own programs
        return ch

    def _send(self, frame):
        if self.kind == "dmx_par":
            self.dmx.set(frame, start=self.addr)
            return
        if self.kind == "pyramid":
            n = self.legs
            legs = frame[: 4 * n].reshape(4, n, 3)
            if self.cfg.get("from_apex"):
                legs = legs[:, ::-1]
            if self.diagonals:
                self.out.send_array(legs[0]); self.out2.send_array(legs[1])
                return
            frame = legs[0] if self.mirrored else np.vstack([legs.reshape(4 * n, 3), frame[4 * n:]])
        self.out.send_array(frame)


# ---------------------------------------------------------------- commander

def make_handler(engine):
    page = (HERE / "commander.html")

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")   # other pages read the state (e.g. simulation audio)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if s5auth.handle(self):
                return
            if self.path.split("?", 1)[0] == "/s5auth.js":
                return self._send(200, (HERE / "s5auth.js").read_bytes(), "text/javascript")
            if self.path.startswith("/api/state"):
                self._send(200, json.dumps(engine.state).encode())
            else:
                self._send(200, page.read_bytes(), "text/html; charset=utf-8")

        def do_POST(self):
            # /api/visual_colour is open (like the projector's /api/screen): the projector service posts the
            # picture's main colour; it only steers the lights while an admin has the palette on Visuals.
            if s5auth.handle(self) or not s5auth.guard(self, allow=("/api/visual_colour",)):
                return
            n = int(self.headers.get("Content-Length", 0))
            if self.path.split("?", 1)[0] == "/api/visual_colour":
                try:
                    d = json.loads(self.rfile.read(n) or b"{}")
                    if d.get("hue") is not None:     # null (no colour on screen) just lets the last one go stale
                        engine.visual = {"hue": float(d["hue"]) % 1.0, "sat": float(d.get("sat", 1.0)), "t": time.time()}
                    self._send(200, b'{"ok": true}')
                except Exception as e:
                    self._send(400, json.dumps({"ok": False, "error": str(e)}).encode())
                return
            try:
                res = engine.command(json.loads(self.rfile.read(n) or b"{}"))
                self._send(200, json.dumps(res).encode())
            except Exception as e:
                self._send(400, json.dumps({"ok": False, "error": str(e)}).encode())
    return H


# ---------------------------------------------------------------- main

def main():
    decks = Decks()
    engine = Engine(decks)
    strips = [c for c in CONFIG["fixtures"] if c["kind"] == "strip"]
    fixtures = [Fixture(c, strips.index(c) if c in strips else 0, len(strips)) for c in CONFIG["fixtures"]]
    engine.fixture_ctl = {f.name: {"on": True, "level": 1.0} for f in fixtures}
    port = CONFIG.get("commander_port", 8090)
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", port), make_handler(engine)).serve_forever,
                     daemon=True).start()
    log(f"showbrain up: {len(fixtures)} fixtures, commander on :{port}")
    fps = CONFIG.get("fps", 50)
    last_scene = None
    idle_since = None
    fps_meas, frames, fps_t = 0.0, 0, time.time()
    n = 0
    while True:
        t0 = time.time()
        frames += 1
        n += 1
        if t0 - fps_t >= 2:
            fps_meas, frames, fps_t = frames / (t0 - fps_t), 0, t0
        ctx = engine.shape(engine.decide(t0), t0)
        if engine.mode == "blackout":
            ctx["scene"] = "PREDROP"
        ctx = engine.react(ctx, t0)
        fx = engine.output_fx(ctx, t0)
        engine.state = {k: v for k, v in ctx.items()} | {
            "mode": engine.mode, "follow": engine.follow, "lead_ms": engine.lead_ms,
            "intensity": engine.intensity, "hold": engine.hold, "strobe": engine.strobe,
            "strobe_div": engine.strobe_div, "blinder": engine.blinder, "black_hold": engine.black_hold,
            "look": engine.look, "palette": {"mode": engine.palette_mode, "hue": engine.palette_hue},
            "visual": None if not engine.visual else {"hue": round(engine.visual["hue"], 3), "sat": round(engine.visual["sat"], 2),
                                                      "age_s": round(time.time() - engine.visual["t"], 1)},
            "speed": engine.speed, "tap_bpm": round(engine.tap_bpm, 1),
            "forced": engine.forced, "fixtures": [f.name for f in fixtures],
            "fixture_info": {f.name: {"kind": f.kind, "leds": f.cfg.get("leds") or (f.out.count if f.kind == "pyramid" else None),
                                      "legs": f.legs if f.kind == "pyramid" else None, "reverse": bool(f.cfg.get("reverse"))} for f in fixtures},
            "fixture_ctl": engine.fixture_ctl,
            "preview": {f.name: f.preview for f in fixtures},
            "frames": list(engine.frames),
            "fps": round(fps_meas, 1),
            "live_reason": engine.live_reason,
            "mix": engine.mix,
            "mixer_share": {str(k): round(v, 3) for k, v in engine.share_smooth.items()},
            "dmx": {k: d.status for k, d in UDMX_DEVICES.items()}}
        if ctx["scene"] != last_scene:
            extra = f" ({ctx['beats_to_drop']:.1f} beats to drop)" if ctx.get("beats_to_drop") else ""
            log(f"scene {last_scene} -> {ctx['scene']}  deck {ctx['live']} bar {ctx['bar']}{extra}")
            last_scene = ctx["scene"]
        # IDLE: stop streaming so WLED / the panel fall back to their own idle looks.
        if ctx["scene"] == "IDLE":
            idle_since = idle_since or t0
        else:
            idle_since = None
        streaming = idle_since is None or t0 - idle_since < 0.5
        for f in fixtures:                   # every frame's preview: the Stage view plays them all back
            if streaming or f.always:
                f.render(ctx, fx, engine.fixture_ctl[f.name], True)
            else:
                f.preview = []
        # Compact: each fixture's LEDs as one hex string, 6 characters per LED.
        engine.frames.append((round(t0, 3), {f.name: "".join(h[1:] for h in f.preview) for f in fixtures}))
        time.sleep(max(0.0, 1 / fps - (time.time() - t0)))


if __name__ == "__main__":
    main()
