#!/usr/bin/env python3
"""Sektor5 generative visuals: control host on :8110.

A sketch is a GLSL content() function (sketches/NAME.glsl) plus its parameter
schema (sketches/NAME.json). The projector renders it on any surface whose
content is "gen"; this service holds the live parameter values and pushes every
change to the projector and to the control page.

  /                 control page (sliders, randomise, presets, live preview)
  /render.js        the projector's renderer, reused for the preview
  /api/events       Server-Sent Events: {"t":"sketch"}, {"t":"params"}, {"t":"state"} ~20x/s,
                    {"t":"wave"} once per track (the live track's waveform, see trackwave.py)
  /api/wave         GET the current waveform message
  /api/sketch       GET the active sketch (name, schema, glsl)
  /api/sketches     GET sketch names
  /api/sketches/NAME  GET any sketch (schema, glsl) with its values, for a projection surface that
                    shows it: live if it's active, else as last left; ?preset=P applies a preset
  /api/params       GET current values; POST {"id": value, ...} to change some
  /api/auto         GET per-parameter automation; POST {"id": {...}, ...} to change some,
                    "_freeze" to hold it, "_play": {"on", "amount" 0..1} for the knob player
  /api/text         GET the words sketches can draw; POST {"text": "ONE|TWO"} to change them
  /api/select       POST {"sketch": NAME} to switch sketch
  /api/shuffle      GET Shuffle's state; POST {"on", "theme", "every", "skip"} to change it (see below)
  /api/presets      GET preset names for the active sketch (?sketch=NAME for another one; &values=1 with their values)
  /api/presets/NAME GET a preset; POST saves current values as NAME; POST .../NAME/load
  /api/transition   GET the transition settings (and the types); POST {"type", "beats", "sync", "pool"
                    (now, beat, bar, phrase, or drop: land on the next predicted drop),
                    "presets"} to change them. Switching sketch (and loading a preset, if
                    "presets") hands over through a transition, synced to the beat.
  /api/next         POST: mix to Shuffle's next pick (theme, next up, ticked in) through a transition

Themes (sketches/themes.json) group the sketches for the Visuals page. Shuffle picks a sketch from
one theme, with one of its presets, every so many bars on the downbeat. It runs here, not in a page,
so it keeps going with no page open.

Live values and presets live in state/ next to this file (not in git). Presets can also ship
with a sketch in sketches/presets/NAME/ (in git); one saved on the brain with the same name wins.

    python3 visuals.py [port]
"""
import collections
import gzip
import hashlib
import json
import math
import os
import queue
import random
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
import zlib
from email.utils import formatdate
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

import s5auth
from pathlib import Path

import trackwave

HERE = Path(__file__).resolve().parent
WEB = HERE / "web"
SKETCHES = HERE / "sketches"
STATE = HERE / "state"
RENDER_JS = HERE.parent / "projector" / "web" / "render.js"   # brain/projector in the repo, ~/projector on the Pi
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8110
SHOWBRAIN = "http://127.0.0.1:8090/api/state"
DECKDASH = "http://127.0.0.1:8080"
STATE_HZ = 20
SAFE_NAME = re.compile(r"^[A-Za-z0-9 _.-]{1,40}$")

lock = threading.Lock()
clients = []            # queue.Queue per connected page
sketch = None           # {"name", "title", "about", "groups", "glsl"}
values = {}             # param id -> float
auto = {}               # param id -> automation settings (see AUTO_KEYS)
auto_freeze = False     # hold every automated value where it is (the page's Freeze)
play = {"on": True, "amount": 0.5}   # the knob player: render.js rides the knobs with the song (playEval)
text = "SEKTOR5"        # words for sketches that draw type, split on | or newline (see word() in COMMON)
TEXT_MAX = 240
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
last_state = b"null"
last_state_at = 0.0     # when last_state was fetched, to extrapolate the beat from
wave = None             # the live track's waveform message (trackwave.py)

# Transitions (render.js draws them). Each type is a shader mode; "auto" picks one that suits the
# song section showbrain is in, and a length for it; "cut" is an instant change on the sync point.
TRANS_TYPES = ["crossfade", "wipe", "iris", "dissolve", "luma", "tiles", "slices", "zoom", "swirl",
               "stutter", "flash", "pixelate"]
TRANS_BEATS = {"crossfade": 8, "dissolve": 8, "luma": 8, "wipe": 4, "iris": 4, "tiles": 4, "slices": 4,
               "zoom": 4, "swirl": 4, "pixelate": 4, "stutter": 2, "flash": 1, "cut": 0}
TRANS_AUTO = [   # (song sections, the types that suit them, beats)
    (("DROP", "PREDROP"), ["flash", "stutter", "zoom"], None),
    (("BUILD", "HOLD"), ["zoom", "swirl", "pixelate", "tiles"], 4),
    (("BREAKDOWN", "INTRO", "OUTRO", "PAUSED", "IDLE"), ["dissolve", "luma", "crossfade", "iris"], 16),
]
TRANS_GROOVE = ["wipe", "iris", "tiles", "slices", "dissolve", "pixelate", "swirl"]
transition = {"type": "auto", "beats": 0, "sync": "bar", "presets": True}   # beats 0 = the type's own
last_type = None


def code_version():
    """Changes whenever the control page or the shared renderer changes (a deploy), so pages reload."""
    h = hashlib.sha1()
    for f in sorted([*WEB.rglob("*"), RENDER_JS]):
        if f.is_file():
            st = f.stat()
            h.update(f"{f.name}{st.st_mtime_ns}{st.st_size}".encode())
    return h.hexdigest()[:12]


def log(msg):
    print(time.strftime("%X"), msg, flush=True)


def sketch_names():
    return sorted(p.stem for p in SKETCHES.glob("*.glsl") if (SKETCHES / f"{p.stem}.json").is_file())


def params_of(sk):
    return [p for g in sk["groups"] for p in g["params"]]


# Per-parameter automation, evaluated in render.js (see the note there). Held here so it is
# shared by every page and projector, saved with the live values, and stored in presets.
# lo/hi are the range the value is allowed to move between, and double as the range Randomise
# works within; they are always clamped to the parameter's own min/max.
AUTO_KEYS = {"on": bool, "lo": float, "hi": float, "rate": float,
             "shape": int, "phase": float, "retrig": bool, "hz": bool, "duty": float}


def auto_default(p):
    return {"on": False, "lo": float(p["min"]), "hi": float(p["max"]),
            "rate": 0.25, "shape": 0, "phase": 0.0, "retrig": False, "hz": False, "duty": 0.5}


def auto_defaults(sk):
    return {p["id"]: auto_default(p) for p in params_of(sk)}


def clamp_auto(sk, d, base):
    """Merge a partial automation update in, keeping every field inside what the sketch allows."""
    out = {k: dict(v) for k, v in base.items()}
    for p in params_of(sk):
        pid = p["id"]
        got = d.get(pid)
        if not isinstance(got, dict):
            continue
        cur = out.setdefault(pid, auto_default(p))
        for k, cast in AUTO_KEYS.items():
            if k not in got:
                continue
            try:
                x = cast(got[k]) if cast is not bool else bool(got[k])
            except (TypeError, ValueError, OverflowError):
                continue
            # json.loads accepts NaN and Infinity. Stored, they come back out as bare NaN, which
            # the pages' JSON.parse rejects -- every page would stop hearing about automation.
            if cast is float and not math.isfinite(x):
                continue
            cur[k] = x
        lo, hi = max(p["min"], min(p["max"], cur["lo"])), max(p["min"], min(p["max"], cur["hi"]))
        cur["lo"], cur["hi"] = min(lo, hi), max(lo, hi)
        cur["rate"] = max(0.0, min(64.0, cur["rate"]))
        cur["shape"] = max(0, min(6, cur["shape"]))
        cur["phase"] = cur["phase"] % 1.0
        cur["duty"] = max(0.02, min(0.98, cur.get("duty", 0.5)))
    return out


def clamp_values(sk, d, base):
    out = dict(base)
    for p in params_of(sk):
        if p["id"] in d:
            try:
                out[p["id"]] = max(p["min"], min(p["max"], float(d[p["id"]])))
            except (TypeError, ValueError):
                pass
    return out


def defaults(sk):
    return {p["id"]: float(p["default"]) for p in params_of(sk)}


def load_sketch(name):
    meta = json.loads((SKETCHES / f"{name}.json").read_text())
    meta.update(name=name, glsl=(SKETCHES / f"{name}.glsl").read_text())
    return meta


def clean_text(v):
    """Whatever the page sent, made safe to draw: no control characters, a sane length."""
    t = CTRL.sub("", str(v or "")).replace("\r", "")
    return t[:TEXT_MAX]


def split_saved(d):
    """A saved blob, old or new. Before automation existed a file was a flat {id: value}."""
    if isinstance(d, dict) and isinstance(d.get("values"), dict):
        return d["values"], d.get("auto") or {}, d.get("text")
    return (d if isinstance(d, dict) else {}), {}, None


def select(name):
    """Make NAME the active sketch, restoring its last values, automation and words."""
    global sketch, values, auto, text, current_preset
    sk = load_sketch(name)
    saved = {}
    try:
        saved = json.loads((STATE / f"{name}.current.json").read_text())
    except (OSError, ValueError):
        pass
    v, a, tx = split_saved(saved)
    sketch = sk
    current_preset = None
    values = clamp_values(sk, v, defaults(sk))
    auto = clamp_auto(sk, a, auto_defaults(sk))
    if tx is not None:
        text = clean_text(tx)
    (STATE / "active").write_text(name)


def sketch_mtime(name):
    """When the sketch's files last changed (its .glsl and .json), or 0 if they're gone."""
    try:
        return max((SKETCHES / f"{name}.glsl").stat().st_mtime, (SKETCHES / f"{name}.json").stat().st_mtime)
    except OSError:
        return 0.0


def watch_active():
    """Reload the active sketch when its files change on disk, keeping its values and automation (new
    settings take their defaults), and tell every page. Before this, an edited sketch stayed as it was
    loaded until it was picked again, which looked like the edit hadn't worked."""
    seen = None
    while True:
        time.sleep(1.5)
        try:
            with lock:
                if not sketch:
                    continue
                name, mt = sketch["name"], sketch_mtime(sketch["name"])
                if seen is None or seen[0] != name:
                    seen = (name, mt)
                    continue
                if mt <= seen[1]:
                    continue
                seen = (name, mt)
                load_new(name)
                sk, snap, asnap, frz = sketch, dict(values), {k: dict(v) for k, v in auto.items()}, auto_freeze
            log(f"sketch {name} changed on disk: reloaded")
            broadcast({"t": "sketch", "sketch": sk})
            broadcast({"t": "params", "params": snap})
            broadcast(auto_msg(asnap, frz))
        except Exception as e:                      # a half-written file: try again next time round
            log(f"watch: {e}")


def load_new(name):
    """Swap in a fresh copy of the active sketch from disk. Caller holds the lock."""
    global sketch, values, auto
    sk = load_sketch(name)
    sketch = sk
    values = clamp_values(sk, values, defaults(sk))
    auto = clamp_auto(sk, auto, auto_defaults(sk))


def load_preset(name):
    """Load preset NAME onto the active sketch. Caller holds the lock. False if there is no such preset."""
    global values, auto, text, current_preset
    f = preset_file(name)
    if not f.is_file():
        return False
    # A preset written before automation existed is a flat {id: value}; it loads with the
    # automation back at its defaults, which is off.
    v, a, tx = split_saved(json.loads(f.read_text()))
    values = clamp_values(sketch, v, defaults(sketch))
    auto = clamp_auto(sketch, a, auto_defaults(sketch))
    if tx is not None:
        text = clean_text(tx)
    current_preset = name
    save_values()
    return True


def save_transition():
    (STATE / "transition.json").write_text(json.dumps(transition, indent=1))


def scene_now():
    try:
        return (json.loads(last_state) or {}).get("scene") or "GROOVE"
    except ValueError:
        return "GROOVE"


def clean_trans(d):
    """Transition settings from a request, checked: a bad value is an error (nothing changes)."""
    if not isinstance(d, dict):
        raise ValueError("transition must be an object")
    out = {}
    if "type" in d:
        if d["type"] not in ["auto", "pick", "cut", "none"] + TRANS_TYPES:
            raise ValueError(f"unknown transition type {d['type']!r}")
        out["type"] = d["type"]
    if "beats" in d:
        b = float(d["beats"])
        if not math.isfinite(b):
            raise ValueError("beats must be a number")
        out["beats"] = max(0.0, min(64.0, b))
    if "sync" in d:
        if d["sync"] not in ("now", "beat", "bar", "phrase", "drop"):
            raise ValueError(f"unknown sync {d['sync']!r}")
        out["sync"] = d["sync"]
    if "presets" in d:
        out["presets"] = bool(d["presets"])
    if "pool" in d:                  # the transitions "pick" chooses from (ticked on the page)
        pool = d["pool"]
        if not isinstance(pool, list) or any(x not in ["cut"] + TRANS_TYPES for x in pool):
            raise ValueError("pool must be a list of transition types")
        out["pool"] = [x for x in ["cut"] + TRANS_TYPES if x in pool]
    return out


def beats_to_drop_now():
    """Beats to the next drop showbrain predicts from the track's analysis, or None."""
    try:
        v = (json.loads(last_state) or {}).get("beats_to_drop")
        return float(v) if v is not None else None
    except (ValueError, TypeError):
        return None


def make_trans(override=None):
    """The transition message for a change now: its type (auto picks one for the song section,
    not the same as last time), length in beats, sync point and a seed. None for an instant change."""
    global last_type
    t = dict(transition, **(override or {}))
    kind, beats = t.get("type", "auto"), float(t.get("beats") or 0)
    if kind == "none":
        return None
    if kind == "pick":               # one of the ticked ones, not the same as last time; none ticked, any
        pool = t.get("pool") or ["cut"] + TRANS_TYPES
        kind = random.choice([x for x in pool if x != last_type] or pool)
    if kind == "auto":
        scene = scene_now()
        pool, auto_beats = TRANS_GROOVE, None
        for scenes, types, b in TRANS_AUTO:
            if scene in scenes:
                pool, auto_beats = types, b
        choices = [x for x in pool if x != last_type] or pool
        kind = random.choice(choices)
        if not beats:
            beats = auto_beats or TRANS_BEATS[kind]
        # Heading into a drop showbrain can see coming: land the change on it.
        btd = beats_to_drop_now()
        if scene in ("BUILD", "HOLD", "PREDROP") and btd is not None and 0 < btd <= 64:
            t["sync"] = "drop"
    if not beats:
        beats = TRANS_BEATS.get(kind, 4)
    last_type = kind
    if kind == "cut":
        return {"type": "cut", "mode": 0, "beats": 0, "sync": t.get("sync", "bar"), "seed": random.random()}
    return {"type": kind, "mode": TRANS_TYPES.index(kind), "beats": beats, "sync": t.get("sync", "bar"),
            "seed": random.random()}


def switch(name, preset=None, override=None, bars=None):
    """Make NAME live (optionally with one of its presets) and tell every page, with a transition:
    the sketch and values first (the pages keep the old automation for the outgoing side), then
    the new sketch's automation and words.

    BARS is set when Shuffle makes the change: it has already picked the downbeat, so the
    transition starts on the next bar whatever the settings say (the renderer lines "bar" up on
    every page, however late the message), is never longer than Shuffle's period, and an instant
    change becomes a cut on that 1. A change by hand gives Shuffle's countdown a full period."""
    with lock:
        select(name)
        if preset:
            load_preset(preset)
        if bars is None:
            shuffle_touch()
        sk, snap = sketch, dict(values)
        asnap, frz, tsnap = {k: dict(v) for k, v in auto.items()}, auto_freeze, text
        tr = make_trans(override)
        if bars is not None:
            tr = dict(tr or {"type": "cut", "mode": 0, "beats": 0, "seed": random.random()}, sync="bar")
            tr["beats"] = min(tr["beats"], bars * 4)
        smsg = shuffle_message()
    broadcast({"t": "sketch", "sketch": sk, "trans": tr})
    broadcast({"t": "params", "params": snap})
    broadcast(auto_msg(asnap, frz))
    broadcast({"t": "text", "text": tsnap})
    broadcast(smsg)
    return tr


def auto_msg(asnap, frz):
    return {"t": "auto", "auto": asnap, "freeze": frz, "play": dict(play)}


def play_set(d):
    """The knob player's settings from a POST (caller holds the lock); kept across a restart."""
    if not isinstance(d, dict):
        return
    if "on" in d:
        play["on"] = bool(d["on"])
    if "amount" in d:
        try:
            a = float(d["amount"])
            if math.isfinite(a):
                play["amount"] = max(0.0, min(1.0, a))
        except (TypeError, ValueError):
            pass
    try:
        (STATE / "play.json").write_text(json.dumps(play))
    except OSError:
        pass


def play_restore():
    try:
        d = json.loads((STATE / "play.json").read_text())
        play.update(on=bool(d.get("on", True)), amount=max(0.0, min(1.0, float(d.get("amount", 0.5)))))
    except (OSError, ValueError, TypeError, AttributeError):
        pass


def save_values():
    (STATE / f"{sketch['name']}.current.json").write_text(
        json.dumps({"_v": 2, "values": values, "auto": auto, "text": text}, indent=1))


def push(data):
    with lock:
        for q in list(clients):
            try:
                q.put_nowait(data)
            except queue.Full:
                pass


def broadcast(obj):
    push(("data: " + json.dumps(obj, separators=(",", ":")) + "\n\n").encode())


def live_title():
    """The track the lights follow (None when nothing plays), from the last state we polled."""
    try:
        s = json.loads(last_state) or {}
    except ValueError:
        return None
    return s.get("title") if s.get("live") else None


def live_player():
    """showbrain's live deck, from the last state we polled."""
    try:
        return (json.loads(last_state) or {}).get("live")
    except ValueError:
        return None


def set_wave(msg):
    global wave
    wave = msg
    log(f"waveform: {msg['source']} {msg.get('title')!r} ({msg['beats']} beats)")
    broadcast({"t": "wave", "wave": msg})


# What the pages don't need from showbrain's state: the lights' pixels and DMX, per-fixture detail and
# the mixer. They're most of its ~23 KB, sent ~20 times a second to every open page; the pages only
# read the clock and the show (beat, bpm, bar, scene, title...). The service itself keeps the whole
# state (last_state) for Shuffle and the drop-timed changes.
PAGE_DROP = ("frames", "preview", "dmx", "fixture_info", "fixture_ctl", "fixtures", "mix", "mixer_share")


def page_state(raw):
    try:
        s = json.loads(raw)
        if isinstance(s, dict):
            for k in PAGE_DROP:
                s.pop(k, None)
            return json.dumps(s, separators=(",", ":")).encode()
    except ValueError:
        pass
    return raw


def poll_state():
    global last_state, last_state_at
    try:
        with urllib.request.urlopen(SHOWBRAIN, timeout=0.3) as r:
            last_state = r.read()
        last_state_at = time.time()
        return b'{"t":"state","s":' + page_state(last_state) + b"}"
    except Exception:
        last_state = b"null"
        return b'{"t":"state","s":null}'


def state_pump():
    """Poll showbrain for the beat clock, while someone is watching or Shuffle is on."""
    while True:
        t0 = time.time()
        if clients:
            payload = poll_state()
            push(b"data: " + payload + b"\n\n")
        elif shuffle["on"]:
            poll_state()          # Shuffle needs the beat even when nobody is watching
        time.sleep(max(0.0, 1 / STATE_HZ - (time.time() - t0)))


def preset_dir(sk_name=None):
    d = STATE / "presets" / (sk_name or sketch["name"])
    d.mkdir(parents=True, exist_ok=True)
    return d


def preset_names(sk_name=None):
    """Saved presets plus the ones shipped with the sketch in git (sketches/presets/NAME/)."""
    shipped = SKETCHES / "presets" / (sk_name or sketch["name"])
    return sorted({p.stem for d in (preset_dir(sk_name), shipped) for p in d.glob("*.json")})


def preset_file(name, sk_name=None):
    """A preset saved on the brain wins over a shipped one of the same name."""
    f = preset_dir(sk_name) / f"{name}.json"
    return f if f.is_file() else SKETCHES / "presets" / (sk_name or sketch["name"]) / f"{name}.json"


def values_for(name, preset=None):
    """A sketch's values for a projection surface that shows it (not necessarily the active one):
    the live values if it's active, else as it was last left on the control page, or its defaults;
    or, if a preset is given, that preset over the defaults."""
    sk = sketch if name == sketch["name"] else load_sketch(name)
    if name == sketch["name"]:
        vals = dict(values)
    else:
        # Both of these go through split_saved: a saved blob is {"values", "auto", "text"} since
        # automation arrived, and reading one as a flat {id: value} finds no ids at all and falls
        # back to the defaults without saying so. Only the values are wanted here -- automation is
        # evaluated in render.js against the sketch the Visuals page is driving, and a surface
        # pinned to some other sketch is not that.
        try:
            saved, _, _ = split_saved(json.loads((STATE / f"{name}.current.json").read_text()))
            vals = clamp_values(sk, saved, defaults(sk))
        except (OSError, ValueError):
            vals = defaults(sk)
    if preset and SAFE_NAME.match(preset):
        f = preset_file(preset, name)
        if f.is_file():
            # Onto the defaults, as loading it on the Visuals page does: a preset lists only what it
            # changes, so laid over the values last left it would come out as a different look.
            pv, _, _ = split_saved(json.loads(f.read_text()))
            vals = clamp_values(sk, pv, defaults(sk))
    return sk, vals


# ---------------------------------------------------------------- themes and Shuffle

THEMES = SKETCHES / "themes.json"
SHUFFLE_EVERY = (1, 2, 4, 8, 16, 32)          # bars
# Shuffle sends its change this early, inside the last beat of the bar. The transition is synced to
# "bar", so every page starts it exactly on the coming downbeat, however late the message arrives.
SHUFFLE_LEAD = 0.35                           # s
# queue: the look to play at the next change, {"sketch", "preset" or None}, then random picks carry on.
# out: per theme, what Shuffle leaves out: {theme: {"sketches": [...], "presets": {sketch: [...]}}}.
# Both only steer Shuffle; anything can still be picked by hand.
# track: a new track coming in (the lights moving to it) mixes to a new look on the next 1, Shuffle on or off.
shuffle = {"on": False, "theme": "all", "every": 8, "queue": None, "out": {}, "track": True}
current_preset = None   # the preset last loaded onto the active sketch, for Shuffle's status
shuf_next = None        # the bar (on the downbeat grid) the next change lands on
shuf_bar = None         # the bar it is now, as far as Shuffle last looked
shuf_skip = False
shuf_title = None       # the live deck's track, as Shuffle last saw it
shuf_done = collections.deque(maxlen=4)   # tracks that have had their new look (mixing in, then going live)
# A mix starting. With no DJ Link mixer the decks can't say whose fader is up, so the other deck
# playing a different track for this many bars counts as the DJ bringing it in.
MIX_IN_BARS = 8
mix_in = None           # the title of a track being mixed in, from deck_watch()
shuf_bags = {}          # what is left to play before anything repeats, per theme and per sketch


def themes():
    """themes.json with the missing sketches dropped, plus Other for any sketch not in a theme."""
    names = sketch_names()
    try:
        raw = json.loads(THEMES.read_text()).get("themes", [])
    except (OSError, ValueError):
        raw = []
    out, seen = [], set()
    for t in raw:
        ss = [n for n in t.get("sketches", []) if n in names and n not in seen]
        seen.update(ss)
        if ss:
            out.append({"id": t["id"], "name": t.get("name", t["id"]), "blurb": t.get("blurb", ""), "sketches": ss})
    rest = [n for n in names if n not in seen]
    if rest:
        out.append({"id": "other", "name": "Other", "blurb": "Not in a theme yet", "sketches": rest})
    return out


def sketch_titles():
    out = {}
    for n in sketch_names():
        try:
            out[n] = json.loads((SKETCHES / f"{n}.json").read_text()).get("title") or n
        except (OSError, ValueError):
            out[n] = n
    return out


def theme_pool(tid):
    ts = themes()
    for t in ts:
        if t["id"] == tid:
            return t["sketches"]
    return [n for t in ts for n in t["sketches"]]


def beat_now(lead=0.0):
    """(beat, beat in bar) as it will be LEAD seconds from now: showbrain's live deck extrapolated
    at its tempo, or a 120 BPM idle clock like the renderer's when nothing is playing."""
    try:
        s = json.loads(last_state) or {}
    except ValueError:
        s = {}
    if s.get("live") and s.get("bpm"):
        b0 = s.get("beat") or 0.0
        beat = b0 + (time.time() + lead - last_state_at) * s["bpm"] / 60
        bwb = ((int(s.get("bwb") or 1) - 1) + math.floor(beat) - math.floor(b0)) % 4 + 1
        return beat, bwb
    beat = (time.time() + lead) * 2
    return beat, math.floor(beat) % 4 + 1


def bar_now(lead=0.0):
    """Which bar we are in, counted so every downbeat is a multiple of 4 (barBeat() in COMMON)."""
    beat, bwb = beat_now(lead)
    return math.floor((beat - (math.floor(beat) - (bwb - 1)) % 4) / 4)


def shuffle_touch():
    """Something was picked by hand: give it a whole period before Shuffle moves on."""
    global shuf_next
    if shuffle["on"]:
        shuf_next = bar_now() + shuffle["every"]


def shuffle_message():
    left = None
    if shuffle["on"] and shuf_next is not None and shuf_bar is not None:
        left = max(1, shuf_next - shuf_bar)
    # A deep copy: the message is serialised after the lock is let go.
    return {"t": "shuffle", "shuffle": dict(json.loads(json.dumps(shuffle)), left=left,
                                            playing=sketch["name"], preset=current_preset)}


def shuffle_message_unlocked():
    with lock:
        return shuffle_message()


def shuffle_save():
    (STATE / "shuffle.json").write_text(json.dumps(shuffle))


def shuffle_restore():
    """Shuffle survives a restart of the brain, on or off, so a set carries on."""
    try:
        d = json.loads((STATE / "shuffle.json").read_text())
        shuffle_set({k: d[k] for k in ("on", "theme", "every", "track") if k in d}, save=False)   # not the queue: a look firing by itself on a restart would be a surprise
        for tid, o in (d.get("out") or {}).items():
            shuffle_set({"out": dict(o, theme=tid)}, save=False)
    except (OSError, ValueError, TypeError, AttributeError):
        pass


def shuffle_set(d, save=True):
    """Change Shuffle from a POST. Caller holds the lock. Returns an error message, or None."""
    global shuf_next, shuf_skip
    if "theme" in d:
        if d["theme"] != "all" and d["theme"] not in [t["id"] for t in themes()]:
            return "no such theme"
        shuffle["theme"] = d["theme"]
    if "every" in d:
        try:
            every = int(d["every"])
        except (TypeError, ValueError):
            return "every must be a number of bars"
        if every not in SHUFFLE_EVERY:
            return f"every must be one of {list(SHUFFLE_EVERY)}"
        shuffle["every"] = every
        shuf_next = None                   # start the new period from here
    if "on" in d:
        on = bool(d["on"])
        if on and not shuffle["on"]:
            shuf_next = None
        shuffle["on"] = on
    if "track" in d:
        shuffle["track"] = bool(d["track"])
    if d.get("skip"):
        shuf_skip = True                   # on the next downbeat; works with Shuffle off too
    if "queue" in d:
        q = d["queue"]
        if not q:
            shuffle["queue"] = None
        else:
            if not isinstance(q, dict) or q.get("sketch") not in sketch_names():
                return "no such sketch to queue"
            p = q.get("preset") or None
            if p is not None and p not in preset_names(q["sketch"]):
                return "no such preset to queue"
            shuffle["queue"] = {"sketch": q["sketch"], "preset": p}
    if "out" in d:
        # The whole of one theme's list at a time, so a page can send what it shows.
        o = d["out"]
        if not isinstance(o, dict):
            return "out must be {theme, sketches, presets}"
        tid = o.get("theme", shuffle["theme"])
        if tid != "all" and tid not in [t["id"] for t in themes()]:
            return "no such theme"
        names = set(sketch_names())
        sk = sorted({n for n in (o.get("sketches") or []) if n in names})
        pr = {n: sorted({p for p in ps if isinstance(p, str)})
              for n, ps in (o.get("presets") or {}).items() if n in names and isinstance(ps, list) and ps}
        if sk or pr:
            shuffle["out"] = dict(shuffle["out"], **{tid: {"sketches": sk, "presets": pr}})
        else:
            shuffle["out"] = {k: v for k, v in shuffle["out"].items() if k != tid}
    if save:
        shuffle_save()
    return None


def shuffle_in(tid):
    """What Shuffle may play from theme TID: (sketches, {sketch: presets left out}). If everything
    has been left out, the whole theme, rather than nothing."""
    pool = theme_pool(tid)
    out = shuffle["out"].get(tid) or {}
    keep = [n for n in pool if n not in (out.get("sketches") or [])]
    return (keep or pool), (out.get("presets") or {})


def shuffle_preset(name, out_presets):
    names = preset_names(name)
    ok = [p for p in names if p not in out_presets.get(name, [])] or names
    pbag = [p for p in shuf_bags.get(("preset", name), []) if p in ok]
    if not pbag and ok:
        pbag = random.sample(ok, len(ok))
    preset = pbag.pop(0) if pbag else None
    shuf_bags[("preset", name)] = pbag
    return preset


def shuffle_pick():
    """The next sketch and preset. Next up, if something is queued; otherwise every sketch Shuffle
    may play in the theme before any repeats, never the one that is playing if there is a choice,
    and every preset of a sketch before its presets repeat."""
    pool, out_presets = shuffle_in(shuffle["theme"])
    q = shuffle["queue"]
    if q and q.get("sketch") in sketch_names():
        shuffle["queue"] = None
        shuffle_save()
        key = ("theme", shuffle["theme"])
        shuf_bags[key] = [n for n in shuf_bags.get(key, []) if n != q["sketch"]]
        preset = q.get("preset") if q.get("preset") in preset_names(q["sketch"]) else shuffle_preset(q["sketch"], {})
        return q["sketch"], preset
    cur = sketch["name"]
    bag = [n for n in shuf_bags.get(("theme", shuffle["theme"]), []) if n in pool and n != cur]
    if not bag:
        bag = random.sample(pool, len(pool))
        if len(bag) > 1 and cur in bag:
            bag.remove(cur)
    name = bag.pop(0)
    shuf_bags[("theme", shuffle["theme"])] = bag
    return name, shuffle_preset(name, out_presets)


def deck_watch():
    """Spot a mix starting (see MIX_IN_BARS) from deckdash's decks, for Shuffle's new-track change."""
    global mix_in
    seen = {}                                          # player -> (title, when it started playing it)
    while True:
        time.sleep(0.5)
        try:
            with urllib.request.urlopen(f"{DECKDASH}/api/state", timeout=2) as r:
                players = json.loads(r.read()).get("players", [])
        except (OSError, ValueError):
            continue
        live, now, found = live_player(), time.time(), None
        for p in players:
            n, s, title = p.get("number"), p.get("status") or {}, (p.get("track") or {}).get("title")
            if not s.get("playing") or not title:
                seen.pop(n, None)
                continue
            if seen.get(n, (None,))[0] != title:
                seen[n] = (title, now)
            bpm = max(60.0, float(s.get("effectiveBpm") or 120))
            if live and n != live and now - seen[n][1] >= MIX_IN_BARS * 4 * 60 / bpm:
                found = title
        with lock:
            mix_in = found


def shuffle_loop():
    """Watch the bar count and change the look on the downbeat. Skip lands on the next 1, and
    works with Shuffle off too: it is "something else from this theme, in time"."""
    global shuf_next, shuf_bar, shuf_skip, shuf_title
    skip_at = None
    while True:
        time.sleep(0.04)
        msgs = []
        with lock:
            bar, every = bar_now(SHUFFLE_LEAD), shuffle["every"]
            changed = False
            # A new track restarts the beat count, and a seek can jump it: start the period again.
            if shuf_next is None or (shuf_bar is not None and bar < shuf_bar) or shuf_next - bar > every:
                shuf_next, changed = bar + every, True
            if shuf_skip:
                skip_at, shuf_skip, changed = bar + 1, False, True
            # A new track has come in: a new look on its next 1. Not on a pause and resume of the same
            # track, nor for whatever is already playing when the service starts.
            # A track being mixed in gets it when the mix starts, not again when the lights move to it.
            title = live_title()
            if mix_in and mix_in != title and mix_in not in shuf_done:
                shuf_done.append(mix_in)
                if shuffle["track"]:
                    log(f"shuffle: mixing in {mix_in!r}: a new look on the next 1")
                    skip_at, changed = bar + 1, True
            if title and title != shuf_title:
                if shuf_title is not None and shuffle["track"] and title not in shuf_done:
                    log(f"shuffle: new track {title!r}: a new look on the next 1")
                    skip_at, changed = bar + 1, True
                if title not in shuf_done:
                    shuf_done.append(title)
                shuf_title = title
            if shuffle["queue"] and not shuffle["on"] and skip_at is None:
                skip_at, changed = bar + 1, True               # with Shuffle off, next up plays on the 1
            if skip_at is not None and bar < skip_at - 1:
                skip_at = bar + 1                              # the count went backwards meanwhile
            fire = (shuffle["on"] and bar >= shuf_next) or (skip_at is not None and bar >= skip_at)
            pick = None
            if fire:
                try:
                    pick = shuffle_pick()
                except (OSError, ValueError, KeyError, IndexError) as e:
                    log(f"shuffle: could not pick: {e}")
                shuf_next, skip_at, changed = bar + every, None, True
            # The countdown goes out once a bar while Shuffle is on, and on any change.
            if changed or (shuffle["on"] and bar != shuf_bar):
                shuf_bar = bar
                msgs.append(shuffle_message())
            shuf_bar = bar
        for msg in msgs:
            broadcast(msg)
        if pick:
            try:
                switch(*pick, bars=every)
                log(f"shuffle: {pick[0]}" + (f" / {pick[1]}" if pick[1] else ""))
            except (OSError, ValueError, KeyError) as e:
                log(f"shuffle: could not change: {e}")


# ---------------------------------------------------------------- compression and caching
# Phones on the rig's Wi-Fi get files, JSON and the event stream gzipped (pages, three.js and the
# state shrink several times over), and a file they already have costs a 304, not the whole file
# again (an ETag from its size and time). Through deckdash's HTTPS proxy nothing changes: it passes
# neither Accept-Encoding nor If-None-Match on, so it gets plain responses as before.
GZIP_TYPES = (".html", ".js", ".mjs", ".css", ".json", ".svg", ".glb", ".gltf", ".txt", ".map")
_gz_files = {}          # path -> (mtime_ns, size, gzipped bytes)


class Gz:
    """Mixed into the handler: compressed JSON, static files with ETags, gzipped event streams."""

    def accepts_gzip(self):
        return "gzip" in (self.headers.get("Accept-Encoding") or "")

    def send_bytes(self, code, body, ctype, extra=()):
        gz = len(body) > 1024 and self.accepts_gzip()
        if gz:
            body = gzip.compress(body, compresslevel=6, mtime=0)
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if gz:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, fpath, ctype=None):
        """A static file: 304 if the browser has this version already, else gzipped if it's worth it."""
        st = os.stat(fpath)
        etag = f'"{st.st_mtime_ns:x}-{st.st_size:x}"'
        if etag in (self.headers.get("If-None-Match") or ""):
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return
        with open(fpath, "rb") as f:
            body = f.read()
        gz = self.accepts_gzip() and fpath.lower().endswith(GZIP_TYPES) and len(body) > 1024
        if gz:
            hit = _gz_files.get(fpath)
            if not hit or hit[0] != st.st_mtime_ns or hit[1] != st.st_size:
                hit = _gz_files[fpath] = (st.st_mtime_ns, st.st_size, gzip.compress(body, compresslevel=6, mtime=0))
            body = hit[2]
        self.send_response(200)
        self.send_header("Content-Type", ctype or self.guess_type(fpath))
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", formatdate(st.st_mtime, usegmt=True))
        if gz:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def static(self):
        """Serve the request from the web folder through send_file; False to leave it to the base class."""
        fpath = self.translate_path(self.path)
        if os.path.isdir(fpath):
            if not self.path.split("?", 1)[0].endswith("/"):
                return False                       # the base class redirects to the slash
            fpath = os.path.join(fpath, "index.html")
        if not os.path.isfile(fpath):
            return False
        self.send_file(fpath)
        return True

    def stream_start(self, compress=False):
        """Start an event stream; returns write(bytes). Gzipped (each message flushed at once) only when
        asked for: the Stage's light frames (~200 KB/s, 16x smaller). Small streams stay plain, which is
        cheaper on the brain and the safest for every browser."""
        gz = compress and self.accepts_gzip()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        if gz:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        self.end_headers()
        if not gz:
            def write(d):
                self.wfile.write(d)
                self.wfile.flush()
            return write
        z = zlib.compressobj(1, zlib.DEFLATED, 31)     # level 1: nearly all the gain, a fraction of the CPU

        def write(d):
            self.wfile.write(z.compress(d) + z.flush(zlib.Z_SYNC_FLUSH))
            self.wfile.flush()
        return write


class H(Gz, SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(WEB), **kw)

    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")    # the projector page on :8100 reads these
        super().end_headers()

    def _json(self, code, obj):
        self.send_bytes(code, json.dumps(obj).encode(), "application/json")

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        if s5auth.handle(self):
            return
        path = self.path.split("?", 1)[0]
        if path == "/api/events":
            return self._events()
        if path == "/render.js":
            return self.send_file(str(RENDER_JS), "text/javascript")
        with lock:
            if path == "/api/sketch":
                return self._json(200, sketch)
            if path == "/api/wave":
                return self._json(200 if wave else 404, wave or {"error": "no waveform yet"})
            if path == "/api/sketches":
                return self._json(200, {"sketches": sketch_names(), "active": sketch["name"],
                                        "themes": themes(), "titles": sketch_titles()})
            if path == "/api/shuffle":
                return self._json(200, shuffle_message()["shuffle"])
            if path == "/api/params":
                return self._json(200, values)
            if path == "/api/auto":
                return self._json(200, {"auto": auto, "freeze": auto_freeze, "play": play})
            if path == "/api/text":
                return self._json(200, {"text": text})
            if path == "/api/presets":
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                name = (q.get("sketch") or [None])[0]
                if name and name not in sketch_names():
                    return self._json(404, {"error": "no such sketch"})
                if (q.get("values") or [""])[0] == "1":       # with each one's values (the knob player's control points)
                    sk = sketch if not name or name == sketch["name"] else load_sketch(name)
                    out = {}
                    for n in preset_names(name):
                        try:
                            pv, _, _ = split_saved(json.loads(preset_file(n, name).read_text()))
                            out[n] = clamp_values(sk, pv, {})
                        except (OSError, ValueError):
                            pass
                    return self._json(200, {"presets": preset_names(name), "values": out})
                return self._json(200, {"presets": preset_names(name)})
            if path == "/api/transition":
                return self._json(200, {"settings": transition, "types": ["auto", "pick", "cut"] + TRANS_TYPES + ["none"],
                                        "last": last_type})
            # Any sketch, for a projection surface that shows it: definition + values (?preset=NAME)
            m = re.match(r"^/api/sketches/([^/]+)$", path)
            if m:
                name = urllib.parse.unquote(m.group(1))
                if name not in sketch_names():
                    return self._json(404, {"error": "no such sketch"})
                preset = (urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("preset") or [None])[0]
                sk, vals = values_for(name, preset)
                return self._json(200, {"sketch": sk, "values": vals})
            m = re.match(r"^/api/presets/([^/]+)$", path)
            if m:
                name = urllib.parse.unquote(m.group(1))
                f = preset_file(name)
                if SAFE_NAME.match(name) and f.is_file():
                    return self._json(200, json.loads(f.read_text()))
                return self._json(404, {"error": "no such preset"})
        return self.static() or super().do_GET()

    def do_POST(self):
        global values, auto, auto_freeze, text
        if s5auth.handle(self) or not s5auth.guard(self):
            return
        path = self.path.split("?", 1)[0]
        try:
            if path == "/api/params":
                d = self._body()
                with lock:
                    values = clamp_values(sketch, d, values)
                    save_values()
                    snap = dict(values)
                broadcast({"t": "params", "params": snap})
                return self._json(200, {"ok": True})
            if path == "/api/auto":
                d = self._body()
                with lock:
                    if "_freeze" in d:
                        auto_freeze = bool(d["_freeze"])
                    if "_play" in d:
                        play_set(d["_play"])
                    auto = clamp_auto(sketch, d, auto)
                    save_values()
                    snap = {k: dict(v) for k, v in auto.items()}
                    frz = auto_freeze
                broadcast(auto_msg(snap, frz))
                return self._json(200, {"ok": True})
            if path == "/api/text":
                with lock:
                    text = clean_text(self._body().get("text", ""))
                    save_values()
                    snap = text
                broadcast({"t": "text", "text": snap})
                return self._json(200, {"ok": True})
            if path == "/api/select":
                d = self._body()
                name = d.get("sketch", "")
                if name not in sketch_names():
                    return self._json(404, {"error": "no such sketch"})
                preset, override = d.get("preset"), clean_trans(d.get("transition") or {})
                if preset and not SAFE_NAME.match(str(preset)):
                    return self._json(400, {"error": "bad preset name"})
                tr = switch(name, preset, override)
                return self._json(200, {"ok": True, "trans": tr})
            if path == "/api/next":
                d = self._body()
                override = clean_trans(d.get("transition") or {})
                # Shuffle's own picker: from its theme, Next up first, only what is ticked in.
                with lock:
                    name, preset = shuffle_pick()
                tr = switch(name, preset, override)
                return self._json(200, {"ok": True, "sketch": name, "trans": tr})
            if path == "/api/transition":
                d = clean_trans(self._body())
                with lock:
                    transition.update(d)
                    save_transition()
                    snap = dict(transition)
                broadcast({"t": "transition", "settings": snap})
                return self._json(200, {"ok": True, "settings": snap})
            if path == "/api/shuffle":
                d = self._body()
                with lock:
                    err = shuffle_set(d)
                    if err:
                        return self._json(400, {"error": err})
                    msg = shuffle_message()
                broadcast(msg)
                return self._json(200, {"ok": True})
            m = re.match(r"^/api/presets/([^/]+?)(/load)?$", path)
            if m:
                name = urllib.parse.unquote(m.group(1))
                if not SAFE_NAME.match(name):
                    return self._json(400, {"error": "bad name"})
                tr = None
                with lock:
                    if m.group(2):
                        if not load_preset(name):
                            return self._json(404, {"error": "no such preset"})
                        shuffle_touch()
                        snap = dict(values)
                        asnap = {k: dict(v2) for k, v2 in auto.items()}
                        tsnap = text
                        tr = make_trans() if transition.get("presets") else None
                    else:
                        (preset_dir() / f"{name}.json").write_text(
                            json.dumps({"_v": 2, "values": values, "auto": auto, "text": text}, indent=1))
                        snap = asnap = tsnap = None
                if snap is not None:
                    broadcast(shuffle_message_unlocked())
                    broadcast({"t": "params", "params": snap, "trans": tr})
                    broadcast(auto_msg(asnap, auto_freeze))
                    broadcast({"t": "text", "text": tsnap})
                return self._json(200, {"ok": True})
        except (ValueError, KeyError, TypeError) as e:
            return self._json(400, {"error": str(e)})
        self._json(404, {"error": "not found"})

    def _events(self):
        q = queue.Queue(maxsize=60)
        write = self.stream_start()
        with lock:
            clients.append(q)
            first = ("data: " + json.dumps({"t": "hello", "version": code_version()}) + "\n\n"
                     "data: " + json.dumps({"t": "sketch", "sketch": sketch}) + "\n\n"
                     "data: " + json.dumps({"t": "params", "params": values}) + "\n\n"
                     "data: " + json.dumps(auto_msg(auto, auto_freeze)) + "\n\n"
                     "data: " + json.dumps({"t": "text", "text": text}) + "\n\n"
                     "data: " + json.dumps(shuffle_message()) + "\n\n"
                     "data: " + json.dumps({"t": "transition", "settings": transition}) + "\n\n"
                     + ("data: " + json.dumps({"t": "wave", "wave": wave}) + "\n\n" if wave else "")).encode()
        try:
            write(first)
            while True:
                try:
                    data = q.get(timeout=15)
                except queue.Empty:
                    data = b": keep-alive\n\n"
                write(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with lock:
                if q in clients:
                    clients.remove(q)


if __name__ == "__main__":
    STATE.mkdir(exist_ok=True)
    names = sketch_names()
    try:
        active = (STATE / "active").read_text().strip()
    except OSError:
        active = ""
    select(active if active in names else names[0])
    shuffle_restore()
    play_restore()
    try:
        transition.update(json.loads((STATE / "transition.json").read_text()))
    except (OSError, ValueError):
        pass
    threading.Thread(target=state_pump, daemon=True).start()
    threading.Thread(target=shuffle_loop, daemon=True).start()
    threading.Thread(target=deck_watch, daemon=True).start()
    threading.Thread(target=watch_active, daemon=True).start()
    trackwave.Follower(DECKDASH, STATE, live_player, set_wave).start()
    log(f"visuals up on :{PORT} (sketch {sketch['name']}; {len(names)} available)")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
