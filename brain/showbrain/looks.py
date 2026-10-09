"""Scene looks, vectorised with numpy. Every function returns float RGB in 0..1.

Strips are 1-D (index 0 = bottom of the tube); the panel is 2-D (H x W).
`ctx` comes from Engine.decide(); `role` holds per-fixture variation:
  offset  beats to shift this fixture's clock (0.5 = off-beat partner)
  flip    swap the two-colour alternation in DROP / groove accents
  index   position in the fixture group (comet hand-off between tubes)
  group   number of fixtures sharing the hand-off
"""
import math

import numpy as np

rng = np.random.default_rng()


# No yellow on the rig: hues from orange to green are squeezed so they skip the yellow band.
# Everything outside the window is untouched, and the squeeze is continuous, so fades still glide.
NO_YELLOW = (0.03, 0.36)       # the window that's squeezed (red-orange .. green)
YELLOW = (0.095, 0.25)         # the band that's skipped (amber, yellow, chartreuse): 34-90 degrees


def no_yellow(h):
    a, b = NO_YELLOW
    y0, y1 = YELLOW
    t = (h - a) / (b - a)
    o = a + t * ((b - a) - (y1 - y0))
    o = np.where(o >= y0, o + (y1 - y0), o)
    return np.where((h > a) & (h < b), o, h).astype(np.float32)


def hsv(h, s, v):
    """Vectorised HSV -> RGB. h, s, v broadcast; returns (..., 3). Never yellow (no_yellow)."""
    return _hsv(no_yellow(np.asarray(h, dtype=np.float32) % 1.0), s, v)


def unyellow(fn):
    """Last guard on a fixture's frame: two colours blended in RGB (red under a green comet) can
    still make yellow, so any clearly yellow pixel is turned to orange or green, whichever is nearer,
    keeping its brightness and saturation."""
    def guarded(*a, **k):
        return unyellow_rgb(fn(*a, **k))
    guarded.__doc__, guarded.__name__ = fn.__doc__, fn.__name__
    return guarded


def unyellow_rgb(out):
    """unyellow() for one frame: (..., 3) RGB in 0..1."""
    out = np.asarray(out, np.float32)
    r, g, b = out[..., 0], out[..., 1], out[..., 2]
    mx, mn = out.max(-1), out.min(-1)
    c = mx - mn
    yel = (b == mn) & (c > 0.1 * np.maximum(mx, 1e-6)) & (mx > 0.02)
    if not yel.any():
        return out
    h = np.where(r >= g, (g - b) / np.maximum(c, 1e-6), 2 - (r - b) / np.maximum(c, 1e-6)) / 6   # 0 red .. 1/3 green
    yel &= (h > YELLOW[0]) & (h < YELLOW[1])
    if not yel.any():
        return out
    fixed = _hsv(np.where(h < sum(YELLOW) / 2, YELLOW[0], YELLOW[1]), c / np.maximum(mx, 1e-6), mx)
    return np.where(yel[..., None], fixed, out).astype(np.float32)


def _hsv(h, s, v):
    """Plain HSV -> RGB, yellow allowed (only the guards use it directly)."""
    h = np.asarray(h, dtype=np.float32) % 1.0
    s = np.clip(np.asarray(s, dtype=np.float32), 0, 1)
    v = np.clip(np.asarray(v, dtype=np.float32), 0, 1)
    h, s, v = np.broadcast_arrays(h, s, v)
    i = np.floor(h * 6).astype(np.int32) % 6
    f = h * 6 - np.floor(h * 6)
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    r = np.choose(i, [v, q, p, p, t, v])
    g = np.choose(i, [t, v, v, q, p, p])
    b = np.choose(i, [p, p, t, v, v, q])
    return np.stack([r, g, b], axis=-1)


def lerp(a, b, t):
    t = np.asarray(t, dtype=np.float32)
    if t.ndim:
        t = t[..., None]
    return a + (b - a) * t


def clock(ctx, role):
    """(frac, bwb, beat) for this fixture, shifted by role offset in beats."""
    beat = ctx["beat"] + role.get("offset", 0.0)
    if ctx.get("bar", 0) == 0:            # no timeline: use beat-event phase
        frac = (ctx["frac"] + role.get("offset", 0.0)) % 1.0
        return frac, ctx["bwb"], beat
    return beat % 1.0, ((int(beat) - 1) % 4) + 1 if beat >= 1 else ctx["bwb"], beat


def drive(ctx):
    """How hard the beat hits outside drops and builds: 0.8 in the quietest bars, 1.3 in the loudest."""
    return 0.8 + 0.5 * min(1.0, max(0.0, ctx.get("energy", 0.5)))


# ---------------------------------------------------------------- layered colour
# Three colours at once instead of one and its opposite: the track's hue plus two more, by a scheme
# that changes with the track and every 32 bars. layer() spreads them across the stage and up each
# fixture, drifting a step every 8 bars, so the rig is a gradient rather than one colour.

SCHEMES = (
    (0.0, 1 / 3, 2 / 3),       # triad
    (0.0, 0.42, 0.58),         # split complement
    (0.0, 0.10, 0.50),         # a neighbour and the opposite
    (0.0, -0.10, 0.10),        # analogous: one family of colour
    (0.0, 0.25, 0.50),         # a quarter round, then the opposite
)


def palette(ctx):
    """The three hues for this stretch of the track."""
    seed = sum(ord(c) for c in (ctx.get("title") or "")) * 3 + int(ctx.get("bar", 0)) // 32
    return (ctx["hue"] + np.array(SCHEMES[seed % len(SCHEMES)], np.float32)) % 1.0


def pal(ctx, i):
    """Palette colour i (wraps; i may be an array)."""
    return np.take(palette(ctx), np.asarray(i, dtype=np.int64) % 3)


def layer(ctx, u, x=0.0, shift=0.0):
    """Hue at stage place u (0 far left .. 1 far right) and height or depth x (0..1) in a fixture:
    the palette laid across the rig, each colour held a while then blending into the next."""
    p = palette(ctx)
    t = (np.asarray(u, np.float32) * 0.6 + np.asarray(x, np.float32) * 0.4) * 2 + ctx.get("beat", 0) / 32 + shift
    t = np.mod(t, 3.0)
    i = np.floor(t).astype(np.int64) % 3
    f = np.clip((t - np.floor(t) - 0.25) / 0.5, 0, 1)
    f = f * f * (3 - 2 * f)
    a, b = p[i], p[(i + 1) % 3]
    return (a + (((b - a + 0.5) % 1.0) - 0.5) * f).astype(np.float32)


def place(role):
    """0 far left .. 1 far right."""
    return (stage_pos(role) + 1) / 2


def hat(frac):
    """The off-beat hi-hat: a short flick on the 'and' of every beat."""
    return math.exp(-14 * (frac - 0.5)) if frac >= 0.5 else 0.0


# ---------------------------------------------------------------- interplay
# The lights play off each other instead of all pumping together. Every fixture has a place across
# the stage, -1 (far left, as the crowd sees it) to 1 (far right): pyramid L, tube L, the panel and
# the par can in the middle, tube R, pyramid R. A "play" is a rule for when each place gets hit,
# and every fixture works out its own kick from it, so they stay locked together with no messages
# between them. Left and right are always mirror images, or a call and its answer.

PLAYS = ("together", "alternate", "swap", "bounce", "chase", "out", "in",
         "zigzag", "cross", "stack", "wave", "sparkle")
CALM_PLAYS = ("together", "alternate", "out", "wave", "stack")                      # intro, outro: nothing too busy
DROP_PLAYS = ("alternate", "bounce", "chase", "out", "swap", "zigzag", "cross", "sparkle")   # the drop, after its first bar
FAST_PLAYS = ("bounce", "chase", "out", "in", "zigzag", "cross", "sparkle")        # a short flash reads as motion


def stage_pos(role):
    """-1 .. 1 across the stage: the fixture's "pos", else from its side (pyramids) or its place
    in the strip group (the tubes either side of the DJ), else the middle."""
    if "pos" in role:
        return max(-1.0, min(1.0, float(role["pos"])))
    if "side" in role:
        return float(role["side"])
    g = role.get("group", 1) if role.get("kind", "strip") == "strip" else 1
    return -0.5 + role.get("index", 0) / (g - 1) if g > 1 else 0.0


def play_of(ctx):
    """The play for this stretch: the Commander's, else one picked by the track every 8 bars
    (every 4 in a drop), from the plays that suit the scene."""
    forced = ctx.get("play")
    if forced in PLAYS:
        return forced
    s = ctx["scene"]
    if s in ("INTRO", "OUTRO", "PAUSED"):
        opts, span = CALM_PLAYS, 8
    elif s == "DROP":
        opts, span = DROP_PLAYS, 4
    elif s == "GROOVE":
        opts, span = PLAYS, 8
    else:
        return "together"
    bar = int(ctx.get("bar", 0)) or int(ctx.get("beat", 0) // 4)
    seed = sum(ord(c) for c in (ctx.get("title") or "")) * 7 + bar // span
    return opts[seed % len(opts)]


def _hits(play, pos, beat):
    """(period in beats, [when in it this place is hit]). pos may be an array (the panel's columns)."""
    pos = np.asarray(pos, dtype=np.float32)
    left, right = pos < -0.01, pos > 0.01
    u = (pos + 1) / 2                                   # 0 far left .. 1 far right
    d = np.abs(pos)                                     # 0 middle .. 1 the ends
    if play == "alternate":                             # left on 1 and 3, right on 2 and 4, the middle on all
        return np.where(left | right, 2.0, 1.0), [np.where(right, 1.0, 0.0)]
    if play == "swap":                                  # call and answer: left the first half bar, right the second
        per = np.where(left | right, 4.0, 2.0)
        return per, [np.where(right, 2.0, 0.0), np.where(right, 3.0, np.where(left, 1.0, 0.0))]
    if play == "bounce":                                # a ball across the stage: left to right, then back
        return 2.0, [u, 2.0 - u]
    if play == "chase":                                 # across on the 16ths every other beat, the other way each bar
        right_way = (int(beat // 4) % 2) == 0
        return 2.0, [u if right_way else 1 - u]
    if play == "out":                                   # the middle on the beat, out to the ends by the 'and'
        return 1.0, [0.5 * d]
    if play == "in":                                    # the ends on the beat, in to the middle by the 'and'
        return 1.0, [0.5 * (1 - d)]
    if play == "zigzag":                                # side to side on the 16ths, ends in to the middle, then back out
        first = (1 - d) + np.where(right, 0.25, 0.0)    # L end 0, R end .25, L inner .5, R inner .75, middle 1
        return 2.0, [first, 2.0 - first]
    if play == "cross":                                 # the diagonals trade 8ths: L end + R inner, then R end + L inner
        a = (left & (d > 0.75)) | (right & (d <= 0.75))
        b = (right & (d > 0.75)) | (left & (d <= 0.75))
        first = np.where(a, 0.0, np.where(b, 0.5, 0.25))
        return 1.0, [first, np.where(a | b, first, 0.75)]   # the middle answers on both 16ths between
    if play == "stack":                                 # builds out across the bar: the middle, then the inner pair, then the ends
        start = np.floor(np.minimum(d, 0.999) * 3)      # beat each place joins in (0, 1, 2)
        return 4.0, [np.maximum(float(j), start) for j in range(4)]
    return 1.0, [0.0 * pos]


def _sparkle(pos, beat, steps=6, chance=0.35):
    """Random places on the 16ths, the same on every fixture (a hash of the 16th and the place, so
    nothing is sent between them). Beats since this place's last sparkle, or a large number."""
    slot = np.round(np.asarray(pos, dtype=np.float64) * 8).astype(np.int64) + 16
    now = beat * 4
    s0 = int(math.floor(now))
    since = np.full(slot.shape, 99.0)
    for j in range(steps - 1, -1, -1):                  # oldest first, so the newest sparkle wins
        s = s0 - j
        lucky = (((s * 73856093) ^ (slot * 19349663)) % 1009) / 1009.0 < chance
        since = np.where(lucky, (now - s) / 4, since)
    return since


def _wave(pos, beat):
    """A soft hump rolling across the stage, left to right over 2 beats and back over the next 2."""
    u = (np.asarray(pos, dtype=np.float32) + 1) / 2
    ph = (beat % 4) / 2
    at = ph if ph < 1 else 2 - ph
    return np.exp(-((u - at) / 0.22) ** 2)


def hit(ctx, role, pos=None):
    """This fixture's kick under the play: 1 as it's hit, decaying until its next hit.
    pos overrides where it stands (an array for the panel, so a bounce travels across it)."""
    frac, bwb, beat = clock(ctx, role)
    # Beats from a downbeat (beat 1 is the first downbeat); with no timeline, the beat events' place in the bar.
    beat = beat - 1 if ctx.get("bar") else (bwb - 1) + frac
    play = play_of(ctx)
    where = stage_pos(role) if pos is None else pos
    if play == "wave":
        k = _wave(where, beat)
        return float(k) if np.ndim(k) == 0 else k
    if play == "sparkle":
        since = _sparkle(where, beat)
    else:
        period, phases = _hits(play, where, beat)
        since = np.min([np.mod(beat - ph, period) for ph in phases], axis=0)
    k = np.exp(-(10.0 if play in FAST_PLAYS else 6.0) * since)
    return float(k) if np.ndim(k) == 0 else k


# ---------------------------------------------------------------- waveform lights
# The lights draw the track itself: rekordbox's colour waveform at full detail (150 frames a
# second), read at the playhead (showbrain puts it in ctx["_wave"], with the frame now and frames a
# beat). Tubes: the next two beats fall down the tube and land at the bottom as you hear them.
# Pyramids: each leg a level meter (bass, mids, highs, everything). Panel: a scrolling waveform,
# rekordbox-style, the playhead in the middle. Par can: coloured and dimmed by the bands. Bass,
# mids and highs take the three palette colours. Picked for some phrases (wave_on), never in a
# build, a hold or the pre-drop, which have their own looks.

def wave_on(ctx):
    """Whether the lights draw the waveform now: the Commander's on / off, else by the track, for
    some 8-bar phrases of a groove, intro, outro or breakdown and some 4-bar phrases of a drop
    (after its first bar)."""
    mode = ctx.get("wave_mode", "auto")
    if mode == "off" or ctx.get("_wave") is None:
        return False
    s = ctx["scene"]
    if s in ("BUILD", "HOLD", "PREDROP", "PAUSED", "IDLE"):
        return False
    if mode == "on":
        return True
    if s == "DROP":
        if ctx.get("since_drop", 0) < 4:
            return False
        span, chance = 4, 0.25
    else:
        span, chance = 8, 0.3 if s == "GROOVE" else 0.35
    bar = int(ctx.get("bar", 0))
    seed = sum(ord(c) for c in (ctx.get("title") or "")) * 13 + bar // span
    return _jhash(seed * 0.71 + 3.3) < chance


def wave_window(ctx, n, behind, ahead):
    """(n, 4): the waveform from `behind` beats before the playhead to `ahead` beats after it,
    as height, bass, mids, highs in 0..1."""
    d, f0, fpb = ctx["_wave"], ctx["_wave_f"], ctx["_wave_fpb"]
    i = np.clip((f0 + np.linspace(-behind * fpb, ahead * fpb, n)).astype(int), 0, len(d) - 1)
    v = d[i].astype(np.float32)
    return v / np.array([31.0, 255.0, 255.0, 255.0], np.float32)


def wave_now(ctx):
    """(height, bass, mids, highs) now: the loudest of the last ~40 ms, so meters don't flicker."""
    return wave_window(ctx, 7, 0.08, 0.0).max(axis=0)


def wave_colour(ctx, v):
    """Colour for waveform samples v (..., 4): the palette's three colours mixed by bass, mids and
    highs (like rekordbox's red, green and blue), as bright as the waveform is tall."""
    P = hsv(palette(ctx), 1.0, 1.0)                                     # (3, 3): bass, mids, highs
    c = v[..., 1:4] @ P
    c = c / np.maximum(c.max(axis=-1, keepdims=True), 1e-4)
    return c * (np.clip(v[..., :1], 0, 1) ** 1.3)


def strip_wave(ctx, n, role):
    v = wave_window(ctx, n, 0.0, 2.0)                                   # bottom = now, top = 2 beats on
    out = wave_colour(ctx, v)
    out[:3] = np.maximum(out[:3], 0.25 * v[0, 0])                       # the landing point glows
    return out[::-1] if role.get("flip") else out


def pyramid_wave(ctx, n, role, order, x):
    lv = wave_now(ctx)                                                  # h, bass, mids, highs
    leg = np.array([lv[1], lv[2], lv[3], lv[0]], np.float32)[order.astype(int).ravel() % 4][:, None]   # (4, 1) level per leg
    band = np.array([1, 2, 3, 0])[order.astype(int).ravel() % 4]
    P = hsv(palette(ctx), 1.0, 1.0)
    col = np.where((band == 0)[:, None], np.ones(3, np.float32), P[np.clip(band - 1, 0, 2)])   # (4, 3)
    fill = (x <= leg).astype(np.float32)[..., None]
    cap = np.exp(-np.abs(x - leg) * 60)[..., None]
    return col[:, None, :] * fill * (0.35 + 0.65 * x[..., None]) + cap * 0.9


def panel_wave(ctx, w, h, X, Y):
    v = wave_window(ctx, w, 1.0, 1.0)                                   # left = a beat ago, right = a beat on
    amp = v[:, 0] * (h - 1) / 2
    on = (np.abs(Y - (h - 1) / 2) <= amp[None, :] + 0.5).astype(np.float32)
    out = wave_colour(ctx, v)[None, :, :] * on[..., None]
    head = np.exp(-np.abs(X - (w - 1) / 2) * 1.5)[..., None]
    return np.maximum(out, head * 0.6)


# ---------------------------------------------------------------- strips

@unyellow
def strip(ctx, n, role, state):
    if wave_on(ctx):
        return strip_wave(ctx, n, role)
    s, hue = ctx["scene"], ctx["hue"]
    x = np.linspace(0, 1, n, dtype=np.float32)
    frac, bwb, beat = clock(ctx, role)
    kick = math.exp(-6 * frac)
    flip = 0.5 if role.get("flip") else 0.0

    if s == "PAUSED":
        kick = 0.0                         # the clock is frozen: no pulse stuck on

    if s == "INTRO":
        v = 0.1 + 0.06 * math.sin(2 * math.pi * beat / 8) + 0.6 * hit(ctx, role) * drive(ctx)
        return hsv(layer(ctx, place(role), x), 0.8, v)

    if s in ("GROOVE", "OUTRO", "PAUSED"):
        fade = {"OUTRO": 0.8, "PAUSED": 0.3}.get(s, 1.0)
        k = 0.0 if s == "PAUSED" else min(1.0, hit(ctx, role) * drive(ctx))
        accent = 0.35 if (bwb == 1) != bool(role.get("flip")) and bwb in (1, 3) else 0.0
        lvl = (0.18 + 0.82 * k + (0.25 * hat(frac) if s != "PAUSED" else 0.0)) * fade
        base = hsv(layer(ctx, place(role), x), 1.0, lvl)
        out = lerp(base, np.full_like(base, lvl), accent * k)
        # Comet climbs the tubes once per bar, handed from one tube to the next.
        g = max(1, role.get("group", 1))
        bar_phase = ((bwb - 1) + frac) / 4
        local = bar_phase * g - role.get("index", 0)
        if 0 <= local <= 1.2:
            d = local * (n + 10) - np.arange(n)
            tail = np.where((d >= 0) & (d < 10), np.exp(-d / 3), 0)
            out = lerp(out, hsv(layer(ctx, place(role), 0.5, shift=1.5), 0.6, fade)[None, :].repeat(n, 0), tail)
        return strip_after(ctx, n, role, x, frac, beat, kick, out) if s == "GROOVE" else out

    if s == "BREAKDOWN":
        return strip_after(ctx, n, role, x, frac, beat, kick, strip_breakdown(ctx, n, role, state, x, beat))

    if s in ("BUILD", "HOLD") and ctx.get("build_style", "rise") != "rise":
        return hsv(*build_field(ctx, place(role), x))

    if s in ("BUILD", "HOLD"):
        p = ctx["progress"]
        rate = 1 if p < 0.5 else 2 if p < 0.75 else 4 if p < 0.9 else 8
        on = ((beat * rate) % 1.0) < 0.45
        fill = x <= (0.2 + 0.8 * p)
        col = lerp(hsv(hue, 1, 1), np.ones(3, np.float32), p * 0.8)
        v = (0.3 + 0.7 * p) if on else 0.04
        return np.where(fill[:, None], col * v, 0.0).astype(np.float32)

    if s == "PREDROP":
        return np.zeros((n, 3), np.float32)

    if s == "DROP":
        return strip_drop(ctx, n, role, x, frac, bwb, beat, kick if ctx["since_drop"] < 4 else hit(ctx, role))

    return np.zeros((n, 3), np.float32)


def post_drop(ctx):
    """(beats since the last drop ended, the drop's length in beats) for the 8 bars after a drop, else None."""
    span = ctx.get("drop_bars", 16) * 4
    for d in reversed(ctx.get("drops") or []):
        since = ctx["beat"] - ((d["bar"] - 1) * 4 + 1) - span
        if since >= 0:
            return (since, span) if since < 32 else None
    return None


def strip_after(ctx, n, role, x, frac, beat, kick, out):
    """The 8 bars after a drop, fading into the section's own look: in a groove, a comet up the tube
    every beat (the tubes in opposite directions) and a harder kick; in a breakdown, the drop's
    colours falling as embers over a half-time pulse."""
    pd = post_drop(ctx)
    if pd is None:
        return out
    amt = (1 - pd[0] / 32) ** 1.5
    hue, flip = ctx["hue"], 0.5 if role.get("flip") else 0.0
    if ctx["scene"] == "GROOVE":
        head = frac * 1.25
        d = (head - x) if not role.get("flip") else (head - (1 - x))
        tail = np.where((d >= 0) & (d < 0.2), np.exp(-d * 18), 0.0) * amt
        punch = hsv(hue + flip, 1.0, kick * 0.6 * amt)[None, :]
        return np.maximum(lerp(out, np.ones(3, np.float32)[None, :].repeat(n, 0), tail), punch)
    pulse = math.exp(-5 * (beat % 2)) * amt                # beats 1 and 3
    glow = hsv(hue + 0.5 * (x > 0.5) + flip, 1.0, 0.4 * pulse * (0.3 + 0.7 * x))
    embers = np.zeros(n, np.float32)
    for k in range(5):                                     # falling a tube's height every 4 beats
        pos = 1 - ((beat / 4 + k / 5 + role.get("index", 0) * 0.1) % 1.0)
        embers += np.exp(-np.abs(x - pos) * 40)
    ember = hsv(hue + 0.5 + flip, 0.6, np.clip(embers, 0, 1) * 0.8 * amt)
    return np.maximum(np.maximum(out, glow), ember).astype(np.float32)


def strip_drop(ctx, n, role, x, frac, bwb, beat, kick):
    """The drop climbs through four 4-bar phases instead of settling after the first bar:
    slam (kick hits, colour blocks racing up), chase (comets, the tubes on opposite beats),
    split (bursts from the middle, colours flip every bar, white on 2 and 4) and peak (a
    16th-note strobe that sweeps white over the last two beats into what comes next)."""
    sd, hue = ctx["since_drop"], ctx["hue"]
    flip = 0.5 if role.get("flip") else 0.0
    if sd < 0.25:
        return np.ones((n, 3), np.float32)
    if sd < 4:                                             # the first bar: the strobe
        on = ((sd * 2) % 1.0) <= 0.5
        blocks = (np.arange(n) // 6) + int(sd) + (1 if role.get("flip") else 0)
        return hsv(pal(ctx, blocks), 1.0, (0.35 + 0.65 * kick) if on else 0.0)
    if sd < 16:                                            # slam
        blocks = (np.arange(n) - int(beat * 8)) // 6 + (1 if role.get("flip") else 0)
        return hsv(pal(ctx, blocks), 1.0, 0.25 + 0.75 * kick)
    if sd < 32:                                            # chase
        base = hsv(layer(ctx, place(role), x, shift=2 * flip), 1.0, 0.1 + 0.35 * kick)
        f = (frac + (0.5 if role.get("flip") else 0.0)) % 1.0
        out = base
        for k in (0.0, 0.5):                               # two comets a beat
            head = ((f + k) % 1.0) * 1.3
            pos = head if not role.get("flip") else 1 - head
            d = (pos - x) if not role.get("flip") else (x - pos)
            tail = np.where((d >= 0) & (d < 0.25), np.exp(-d * 14), 0.0)
            out = lerp(out, np.ones(3, np.float32)[None, :].repeat(n, 0), tail)
        return out
    if sd < 48:                                            # split
        bar_hue = pal(ctx, int(sd // 4) + (1 if flip else 0))
        r = np.abs(x - 0.5) * 2
        ring = np.clip(1 - np.abs(r - frac * 1.2) * 6, 0, 1)
        out = hsv(bar_hue + 0.08 * r, 1.0, 0.15 + 0.45 * kick + 0.6 * ring)
        if bwb in (2, 4) and frac < 0.12:                  # white hit on the snare
            out = lerp(out, np.ones((n, 3), np.float32), 1 - frac / 0.12)
        return out
    # peak: 16th gate, hue moving every beat, then a white sweep from the bottom over the last 2 beats
    gate = ((beat * 4) % 1.0) < 0.5
    out = hsv(pal(ctx, int(beat) + (1 if flip else 0)) + 0.1 * x, 1.0, (0.4 + 0.6 * kick) if gate else 0.05)
    left = ctx.get("drop_bars", 16) * 4 - sd
    if left < 2:
        out = np.where((x <= 1 - left / 2)[:, None], 1.0, out).astype(np.float32)
    return out


# ---------------------------------------------------------------- build styles
# Each build picks a style (showbrain: per build, never the same twice running, or latched in the
# Commander), so builds don't all look alike. "rise" is the original: each fixture fills up as the
# strobe doubles (the per-fixture code below). The others are one field across the rig, at stage
# place u (0 left .. 1 right) and height x (0 .. 1), worked out the same way by every fixture:
#   sweep     a bright band scanning across the stage and back, faster and whiter towards the drop
#   converge  hits from the outside fixtures in to the middle every pulse; late on, all together
#   swell     slow saturated breaths that shorten and brighten, hue turning; flicker in the last bar
#   stutter   left and right trade colour hits on a tightening grid, colours stepping each pair
# Their pulse rate climbs the same ladder as rise: 1, 2, 4, 8 a beat at 0, 50, 75, 90% of the build.

BUILD_STYLES = ("rise", "sweep", "converge", "swell", "stutter")


def build_rate(p):
    return 1 if p < 0.5 else 2 if p < 0.75 else 4 if p < 0.9 else 8


def build_phase(ctx):
    """Pulses since the build began, at the ladder's rate: continuous across its steps, so nothing jumps."""
    t, n = ctx.get("build_t", 0.0), max(1.0, ctx.get("build_len", 16.0) - 1)
    ph, prev = 0.0, 0.0
    for edge, rate in ((0.5, 1), (0.75, 2), (0.9, 4), (99.0, 8)):
        ph += rate * max(0.0, min(t, edge * n) - prev)
        prev = edge * n
        if t <= prev:
            break
    return ph


def build_field(ctx, u, x):
    """(hue, saturation, value) of the build at stage place u and height x, for every style but rise."""
    style, p, hue = ctx.get("build_style"), ctx["progress"], ctx["hue"]
    u, x = np.asarray(u, np.float32), np.asarray(x, np.float32)
    ph = build_phase(ctx)
    f = ph % 1.0
    if style == "sweep":                                   # across in 2 pulses, back in 2
        c = 1 - abs(2 * ((ph / 4) % 1.0) - 1)
        band = np.exp(-np.abs(u - c) * (5 + 6 * p))
        h = hue + 0.12 * (c - 0.5) + 0 * x
        sat = 1 - 0.8 * p * band
        v = 0.04 + 0.1 * p + band * (0.45 + 0.55 * p) * (0.6 + 0.4 * x)
    elif style == "converge":                              # the outside in, each pulse
        d = np.abs(u - 0.5) * 2
        front = 1 - f * 1.15
        ring = np.exp(-np.abs(d - front) * 7)
        together = math.exp(-f * 6) * min(1.0, max(0.0, (p - 0.7) * 3.5))
        h = pal(ctx, int(ph)) + 0.06 * x + 0 * u
        sat = 1 - 0.75 * p * np.maximum(ring, together)
        v = 0.05 + 0.08 * p + np.maximum(ring * (0.45 + 0.55 * p), together) * (0.7 + 0.3 * x)
    elif style == "swell":                                 # a breath every 2 pulses
        b = 0.5 - 0.5 * math.cos(math.pi * ph)
        h = layer(ctx, u, x) + 0.35 * p * p
        sat = 1 - 0.6 * p * p + 0 * u
        v = (0.05 + (0.15 + 0.85 * p) * b ** 1.5) * (0.65 + 0.35 * x) + 0 * u
        if (ctx.get("beats_to_drop") or 99) <= 5:             # the last bar: white flicker on the 8ths
            on = ((ctx["beat"] * 2) % 1.0) < 0.5
            sat, v = sat * 0.2, v * 0 + (0.9 if on else 0.08)
    else:                                                  # stutter: left and right trade hits
        spb = max(2, build_rate(p))
        k = int(math.floor(ctx["beat"] * spb))
        mid = np.abs(u - 0.5) < 0.1
        on = mid | ((u < 0.5) == (k % 2 == 0))
        h = pal(ctx, k // 2) + 0.05 * x + 0 * u
        sat = 1 - 0.7 * p + 0 * u
        v = np.where(on, (0.35 + 0.65 * p) * (0.75 + 0.25 * x), 0.03)
    return np.broadcast_arrays(np.asarray(h, np.float32), np.asarray(sat, np.float32), np.asarray(v, np.float32))


# ---------------------------------------------------------------- leg pyramids
# docs/fixtures/leg-pyramids.md: four legs of n LEDs (front-left, front-right, back-right, back-left;
# 0 = the foot), then one pixel for the laser at the apex (on/off). The left and right pyramids
# (role "side" -1 / 1) mirror each other, so a spiral turns towards the DJ on both.

SPIRAL_TURNS = 6          # a spiral goes round the pyramid this many times from the feet to the apex
MIRROR = (1, 0, 3, 2)     # FL<->FR, BR<->BL


def _pyr_grid(n, role):
    """(order of each leg round the pyramid, 4 x 1), (height of each LED, 1 x n). A mirrored pyramid
    (all four legs on one data line, e.g. an SP901E's copies) has every leg in the same place."""
    if role.get("mirrored"):
        return np.zeros((4, 1), np.float32), np.linspace(0, 1, n, dtype=np.float32)[None, :]
    if role.get("diagonals"):                      # two data lines: front-left + back-right, front-right + back-left
        return np.array([0, 1, 0, 1], np.float32)[:, None], np.linspace(0, 1, n, dtype=np.float32)[None, :]
    order = np.arange(4, dtype=np.float32) if role.get("side", -1) < 0 else np.array(MIRROR, np.float32)
    return order[:, None], np.linspace(0, 1, n, dtype=np.float32)[None, :]


def _spiral(order, x, turns=SPIRAL_TURNS, mirrored=False, stations=4):
    """Where each LED sits along a spiral that climbs the four legs in turn (0 at the feet, 1 at the
    apex). With mirrored legs there's no spiral to follow: straight up every leg at once. With the
    legs in two diagonal pairs (stations=2) it climbs one diagonal, then the other."""
    if mirrored:
        return x + 0 * order
    t = x * turns
    seg = np.minimum(np.floor(t), turns - 1)
    return (stations * seg + order + (t - seg)) / (stations * turns)


def _pyr_mode(ctx, options):
    """A look for this stretch of the track: changes with the track and every 16 bars."""
    seed = sum(ord(c) for c in (ctx.get("title") or "")) + int(ctx.get("bar", 0)) // 16
    return options[seed % len(options)]


PYR_LEFT = np.array([1, 0, 0, 1], np.float32)[:, None]   # the legs on the pyramid's left, seen from the front: FL, BL
ACROSS = (0, 1, 2, 3, 3, 2, 1, 0)                        # "across": L's left, L's right, R's left, R's right, and back


def pyr_blast_mask(mode, role, order, beat):
    """(4 x 1): which legs fire on this beat. "blast": one leg a beat round the pyramid; "sides": its
    left pair, then its right pair (the right pyramid mirrored, so outer sides, then inner); "across":
    a side at a time across both pyramids and back, two bars a sweep. With the legs mirrored or in
    diagonal pairs it can't pick legs: the whole pyramid (across: on its own beats)."""
    b = int(math.floor(beat)) - 1                           # 0 on the downbeat (beats count from 1)
    right = role.get("side", -1) > 0
    if mode == "across":
        slot = (2 if right else 0) + (1 - PYR_LEFT)          # this pyramid's left legs, right legs
        on = slot == ACROSS[b % 8]
        if role.get("mirrored") or role.get("diagonals"):
            on = np.full((4, 1), (ACROSS[b % 8] >= 2) == right)
        return on.astype(np.float32)
    if role.get("mirrored") or role.get("diagonals"):
        return np.ones((4, 1), np.float32)
    if mode == "sides":
        outer = (1 - PYR_LEFT) if right else PYR_LEFT        # its outer pair first, then the inner
        return outer if b % 2 == 0 else 1 - outer
    return (order == b % 4).astype(np.float32)               # blast


def pyr_blast(ctx, role, order, x, frac, beat, mode, groove=False, base=None):
    """The beat-blast looks (see pyr_blast_mask). In a drop the firing legs hit full and white-hot,
    then fall back to the drop colour; in a groove they flash the show's colours over a dim base."""
    mask = pyr_blast_mask(mode, role, order, beat)[..., None]   # (4, 1, 1)
    kick = math.exp(-5 * frac)
    white = np.ones(3, np.float32)
    if groove:
        lit = hsv(layer(ctx, place(role), x, shift=1.0 + 0.25 * (int(math.floor(beat)) % 4)), 1.0, (0.3 + 0.7 * kick) * (0.75 + 0.25 * x))
        lit = lerp(lit, white[None, None, :], 0.35 * kick ** 2)
        dim = (base if base is not None else hsv(layer(ctx, place(role), x), 1.0, 0.1)) * 0.35
        return np.where(mask > 0, lit + 0 * dim, dim)
    hue = pal(ctx, int(math.floor(beat)))
    lit = lerp(hsv(hue + 0.08 * x + 0 * order, 1.0, 0.35 + 0.65 * kick), white[None, None, :], 0.8 * kick ** 2)
    dim = hsv(pal(ctx, order) + 0.1 * x, 1.0, 0.06)
    return np.where(mask > 0, lit, dim)


def pyr_drop_phases(ctx):
    """The drop's middle two 4-bar phases, picked per drop (the same on both pyramids)."""
    sd, b = ctx["since_drop"], ctx["beat"]
    start = round(b - sd)
    seed = str_hash(ctx.get("title")) + (ctx.get("live") or 0)
    two = ("rockets", "blast", "sides", "across")
    p2 = two[int(_jhash(start * 0.61 + seed % 991) * len(two)) % len(two)]
    three = [m for m in ("bounce", "blast", "sides", "across") if m != p2]
    p3 = three[int(_jhash(start * 0.29 + seed % 977 + 5.3) * len(three)) % len(three)]
    return p2, p3


@unyellow
def pyramid(ctx, n, role, state):
    """(4n + 1, 3): the legs' LEDs, then the laser (1 = on)."""
    s, hue = ctx["scene"], ctx["hue"]
    frac, bwb, beat = clock(ctx, role)
    kick = math.exp(-6 * frac)
    order, x = _pyr_grid(n, role)
    mir = bool(role.get("mirrored"))
    st = 2 if role.get("diagonals") else 4         # legs (or diagonal pairs) a spiral steps round
    laser = 0.0
    white = np.ones(3, np.float32)

    if wave_on(ctx):
        out = pyramid_wave(ctx, n, role, order, x)
        if s == "DROP":
            laser = 1.0 if pyramid_laser(ctx) else 0.0
    elif s in ("BUILD", "HOLD") and ctx.get("build_style", "rise") != "rise":
        out = hsv(*build_field(ctx, place(role), x)) + 0 * order[..., None]
    elif s in ("BUILD", "HOLD"):
        # The spiral fill: the legs light from the feet in a spiral round the outside, reaching
        # the apex as the build ends; a white head leads it, and the lit part flickers faster near the end.
        p = ctx["progress"]
        sp = _spiral(order, x, mirrored=mir, stations=st)
        head = 0.02 + 0.98 * p
        lit = sp <= head
        rate = 1 if p < 0.5 else 2 if p < 0.75 else 4 if p < 0.9 else 8
        on = ((beat * rate) % 1.0) < 0.5 or s == "HOLD"
        body = hsv(hue + 0.12 * x, 1.0 - 0.6 * p * x, (0.4 + 0.6 * p) * (1.0 if on else 0.3))
        near = np.clip(1 - (head - sp) * 40, 0, 1) * lit
        out = np.where(lit[..., None], body, 0.0)
        out = lerp(out, white[None, None, :], near * (0.6 + 0.4 * kick if s == "HOLD" else 1.0))
    elif s == "PREDROP":
        # Held breath: dark but for the tips of the legs.
        out = np.zeros((4, n, 3), np.float32) + white * np.where(x > 0.9, 0.3, 0.0)[..., None]
    elif s == "DROP":
        sd = ctx["since_drop"]
        if sd < 1:                                     # a white burst down from the apex
            front = 1 - sd
            out = np.where((x >= front)[..., None], white, hsv(hue, 1, 0.1)) + 0 * order[..., None]
        else:
            out = pyramid_drop(ctx, order, x, frac, bwb, beat, kick if sd < 4 else hit(ctx, role), mir, st, role)
        # The laser comes on with the drop: held for the first bar, then a new rhythm each phrase.
        laser = 1.0 if pyramid_laser(ctx) else 0.0
    elif s == "BREAKDOWN":
        # Slow breathing in the complementary colour, brighter towards the apex, and a soft
        # spiral head drifting down every 2 bars.
        breathe = 0.5 - 0.5 * math.cos(beat * math.pi / 4)
        sp = _spiral(order, x, mirrored=mir, stations=st)
        head = 1 - (beat / 8) % 1.0
        glow = np.exp(-np.abs(sp - head) * 30) * 0.5
        lvl = (0.1 + 0.3 * breathe) * (0.5 + 0.5 * x) + glow
        out = pyramid_after(ctx, order, x, frac, beat, kick, mir, st, hsv(hue + 0.5 + 0.1 * x, 0.8 - 0.4 * glow, lvl))
    elif s in ("INTRO", "OUTRO", "PAUSED"):
        fade = {"PAUSED": 0.4, "OUTRO": 0.8}.get(s, 1.0)
        breathe = 0.5 - 0.5 * math.cos(beat * math.pi / 4)
        k = 0.0 if s == "PAUSED" else min(1.0, hit(ctx, role) * drive(ctx))
        out = hsv(layer(ctx, place(role), x, shift=0.25 * order), 0.8, (0.08 + 0.12 * breathe + 0.55 * k) * (0.4 + 0.6 * x) * fade)
    else:
        # GROOVE (and anything else): the feet pulse with the kick, plus, by track and every 16
        # bars, an orbiting comet (one leg a beat, round the pyramid) or a spiral chase (a bar a lap).
        k = min(1.0, hit(ctx, role) * drive(ctx))
        base = hsv(layer(ctx, place(role), x, shift=0.2 * order), 1.0, (0.2 + 0.8 * k + 0.2 * hat(frac)) * (1 - 0.4 * x))
        gmode = _pyr_mode(ctx, ("orbit", "spiral", "blast", "sides", "across"))
        if gmode in ("blast", "sides", "across"):
            tail = None
        elif gmode == "orbit":
            headx = frac * 1.15
            tail = np.clip(1 - (headx - x) * 5, 0, 1) * (x <= headx) * (True if mir else (order == (bwb - 1) % st))   # mirrored: up every leg each beat
        else:
            sp = _spiral(order, x, mirrored=mir, stations=st)
            headp = ((bwb - 1) + frac) / 4
            d = headp - sp
            tail = np.where((d >= 0) & (d < 0.12), np.exp(-d * 30), 0.0)
        if tail is None:
            out = pyr_blast(ctx, role, order, x, frac, beat, gmode, groove=True, base=base)
        else:
            out = lerp(base, hsv(layer(ctx, place(role), x, shift=1.5), 0.35, 1.0), tail * 0.9)
        if s == "GROOVE":
            out = pyramid_after(ctx, order, x, frac, beat, kick, mir, st, out)
    legs =np.broadcast_to(np.asarray(out, np.float32), (4, n, 3)).reshape(4 * n, 3)   # a look can be one leg tall
    return np.vstack([legs, np.full((1, 3), laser, np.float32)])


PYR_LASER = ("kick", "one", "offbeat", "gallop", "triplet", "tresillo", "bars", "eighths")


def _jhash(n):
    """lasershow.js hash(): the same numbers, so the Stage view's pyramids match the real ones."""
    x = math.sin(n * 127.1 + 311.7) * 43758.5453
    return x - math.floor(x)


def str_hash(s):
    """lasershow.js strHash()."""
    h = 7
    for c in str(s or ""):
        h = (h * 31 + ord(c)) & 0xFFFFFFFF
    return abs(h - (1 << 32) if h >= 1 << 31 else h)


def pyramid_laser(ctx):
    """The pyramids' on/off sky lasers in a drop: held for the first bar, then a rhythm per 4-bar
    phrase picked by the track and the drop, never the same twice running, so drops don't repeat.
    Mirrors pyramidLaserOn() in lasershow.js."""
    sd, b = ctx["since_drop"], ctx["beat"]
    if sd < 4:
        return True
    start, seed = round(b - sd), str_hash(ctx.get("title")) + (ctx.get("live") or 0)
    last, pat = -1, 0
    for i in range(int(sd // 16) + 1):
        pat = int(_jhash(start * 0.37 + i * 13.1 + seed % 997) * (len(PYR_LASER) - 1))
        if last >= 0 and pat >= last:
            pat += 1
        last = pat
    f = lambda v: v - math.floor(v)
    name = PYR_LASER[pat]
    if name == "kick":
        return f(b) < 0.5
    if name == "one":
        return f(b / 4) < 0.125
    if name == "offbeat":
        return 0.5 <= f(b) < 0.85
    if name == "gallop":
        return int(f(b) * 4) in (0, 2, 3)
    if name == "triplet":
        return f(b * 3) < 0.5
    if name == "tresillo":
        return int(f(b / 2) * 8) in (0, 3, 6)
    if name == "bars":
        return f(b / 8) < 0.5 or f(b) < 0.5
    return f(b * 2) < 0.5


def pyramid_drop(ctx, order, x, frac, bwb, beat, kick, mir, st, role=None):
    """After the burst, four 4-bar phases: slam (a ring falls from the apex every beat over
    alternating colours), then two picked per drop (pyr_drop_phases): rockets (white heads shoot
    from the feet to the apex, round the legs unless they're mirrored), bounce (the legs fill to the
    kick like a level meter, the colour flipping every bar, a white cap on top) or a beat blast
    (blast, sides, across: pyr_blast), and last peak (a 16th-note strobe, then white fills from the
    feet over the last two beats)."""
    sd, hue = ctx["since_drop"], ctx["hue"]
    white = np.ones(3, np.float32)
    if 16 <= sd < 48:
        mode = pyr_drop_phases(ctx)[0 if sd < 32 else 1]
        if mode in ("blast", "sides", "across"):
            return pyr_blast(ctx, role or {}, order, x, frac, beat, mode)
        # else rockets (only ever picked for 16-32) or bounce (only 32-48): the phases below
    if sd < 16:                                            # slam
        base = hsv(pal(ctx, order + int(sd // 4)) + 0 * x, 1.0, 0.5 + 0.5 * kick)
        ring = np.clip(1 - np.abs((1 - x) - frac) * 7, 0, 1)
        return lerp(base, white[None, None, :], ring * 0.75)
    if sd < 32:                                            # rockets
        base = hsv(pal(ctx, order) + 0.1 * x, 1.0, 0.15 + 0.4 * kick)
        sp = _spiral(order, x, turns=1, mirrored=mir, stations=st)
        head = min(1.0, frac * 2) * 1.1
        d = head - sp
        tail = np.where((d >= 0) & (d < 0.3), np.exp(-d * 10), 0.0)
        return lerp(base, white[None, None, :], tail)
    if sd < 48:                                            # bounce
        level = 0.25 + 0.75 * kick
        bar_hue = pal(ctx, int(sd // 4) + order)
        on = x <= level
        cap = np.clip(1 - np.abs(x - level) * 25, 0, 1)
        out = np.where(on[..., None], hsv(bar_hue + 0.1 * x, 1.0, 0.3 + 0.7 * x), 0.0) + 0 * order[..., None]
        return lerp(out, white[None, None, :], cap)
    gate = ((beat * 4) % 1.0) < 0.5                        # peak
    out = hsv(pal(ctx, int(beat) + order) + 0.1 * x, 1.0, (0.45 + 0.55 * kick) if gate else 0.05)
    left = ctx.get("drop_bars", 16) * 4 - sd
    if left < 2:
        out = np.where((x <= 1 - left / 2)[..., None], white, out)
    return out


def pyramid_after(ctx, order, x, frac, beat, kick, mir, st, out):
    """The 8 bars after a drop, fading into the section's look: in a groove, a rocket from the feet
    every beat and the whole pyramid on the kick; in a breakdown, a ring falling from the apex
    every two beats in the drop's colours."""
    pd = post_drop(ctx)
    if pd is None:
        return out
    amt = (1 - pd[0] / 32) ** 1.5
    hue, white = ctx["hue"], np.ones(3, np.float32)
    if ctx["scene"] == "GROOVE":
        sp = _spiral(order, x, turns=1, mirrored=mir, stations=st)
        d = frac * 1.2 - sp
        tail = np.where((d >= 0) & (d < 0.25), np.exp(-d * 12), 0.0) * amt
        punch = hsv(hue + (order % 2) * 0.5, 1.0, kick * 0.5 * amt * (0.4 + 0.6 * x))
        return np.maximum(lerp(out, white[None, None, :], tail), punch)
    ph = (beat % 2) / 2
    ring = np.clip(1 - np.abs((1 - x) - ph * 1.1) * 8, 0, 1) * amt
    return np.maximum(out, hsv(hue + (order % 2) * 0.5, 0.7, ring * 0.9))


# ---------------------------------------------------------------- panel

@unyellow
def panel(ctx, w, h, role, state):
    s, hue = ctx["scene"], ctx["hue"]
    X, Y = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    frac, bwb, beat = clock(ctx, role)
    kick = math.exp(-6 * frac)

    if s == "PAUSED":
        kick = 0.0
    centre = 1 - np.abs(Y - (h - 1) / 2) / (h * 0.62)

    cols = stage_pos(role) + (X / max(1, w - 1) - 0.5) * role.get("span", 0.5)   # where each column stands
    if wave_on(ctx):
        return panel_wave(ctx, w, h, X, Y)
    if s == "INTRO":
        v = 0.08 + 0.04 * math.sin(2 * math.pi * beat / 8) + 0.5 * np.minimum(1.0, hit(ctx, role, cols) * drive(ctx)) * centre
        return hsv(layer(ctx, (cols + 1) / 2, Y / max(1, h - 1)), 0.8, v)

    if s in ("GROOVE", "OUTRO", "PAUSED"):
        fade = {"OUTRO": 0.8, "PAUSED": 0.3}.get(s, 1.0)
        k = 0.0 if s == "PAUSED" else np.minimum(1.0, hit(ctx, role, cols) * drive(ctx))
        v = (0.12 + 0.85 * k * centre) * fade
        out = hsv(layer(ctx, (cols + 1) / 2, Y / max(1, h - 1)), 1.0, v)
        head = ((bwb - 1 + frac) / 4) * (w + 24)
        d = head - X
        comet = np.where((d >= 0) & (d < 24), np.exp(-d / 8), 0)
        return lerp(out, hsv(layer(ctx, (cols + 1) / 2, Y / max(1, h - 1), shift=1.5), 0.5, fade), comet)

    if s == "BREAKDOWN":
        return panel_breakdown(ctx, w, h, role, state, X, Y, beat)

    if s in ("BUILD", "HOLD"):
        p = ctx["progress"]
        rate = 1 if p < 0.5 else 2 if p < 0.75 else 4 if p < 0.9 else 8
        on = ((beat * rate) % 1.0) < 0.45
        # Fill closes in from both ends toward the centre.
        reach = (0.15 + 0.85 * p) * w / 2
        mask = np.abs(X - (w - 1) / 2) >= (w / 2 - reach)
        col = lerp(hsv(hue, 1, 1), np.ones(3, np.float32), p * 0.8)
        v = (0.3 + 0.7 * p) if on else 0.03
        return np.where(mask[..., None], col * v, 0.0).astype(np.float32)

    if s == "PREDROP":
        return np.zeros((h, w, 3), np.float32)

    if s == "DROP":
        sd = ctx["since_drop"]
        if sd < 0.25:
            return np.ones((h, w, 3), np.float32)
        radius = (sd % 1.0) * w * 0.6
        ring = np.exp(-np.abs(np.abs(X - w / 2) - radius) / 4)
        k = kick if sd < 4 else hit(ctx, role, cols)
        blocks = (X // max(1, w // 6)).astype(np.int64) + int(sd)    # colour blocks across the panel, stepping each beat
        base = hsv(pal(ctx, blocks), 1.0, (0.3 + 0.7 * k) * 0.5)
        return lerp(base, np.ones(3, np.float32), ring * 0.8)

    return np.zeros((h, w, 3), np.float32)


# ---------------------------------------------------------------- par can (single DMX fixture)

# WLED's "Party" palette, which the tubes' and pyramids' idle Aurora uses.
PARTY = np.array([[0x55, 0x00, 0xAB], [0x84, 0x00, 0x7C], [0xB5, 0x00, 0x4B], [0xE5, 0x00, 0x1B],
                  [0xE8, 0x17, 0x00], [0xB8, 0x47, 0x00], [0xAB, 0x77, 0x00], [0xAB, 0xAB, 0x00],
                  [0xAB, 0x55, 0x00], [0xDD, 0x22, 0x00], [0xF2, 0x00, 0x0E], [0xC2, 0x00, 0x3E],
                  [0x8F, 0x00, 0x71], [0x5F, 0x00, 0xA1], [0x2F, 0x00, 0xD0], [0x00, 0x07, 0xF9]], np.float32) / 255


def par(ctx, role, state):
    """One RGB(W/A/UV) wash light. Returns dict of 0..1 values: dimmer, r, g, b, w, a, uv.
    W/A/UV are only used when the fixture config says those channels are verified."""
    s, hue = ctx["scene"], ctx["hue"]
    frac, bwb, beat = clock(ctx, role)
    kick = math.exp(-6 * frac)
    out = dict(dimmer=1.0, r=0.0, g=0.0, b=0.0, w=0.0, a=0.0, uv=0.0)

    def colour(h, s_=1.0, v=1.0):
        r, g, b = hsv(h, s_, v).tolist()
        out.update(r=r, g=g, b=b)

    if wave_on(ctx):
        c = wave_colour(ctx, wave_now(ctx)).tolist()
        out.update(r=c[0], g=c[1], b=c[2])
    elif s == "IDLE":                                 # waiting: drift through WLED's Party palette, like the
        x = (ctx["t"] / 40.0) % 1.0 * len(PARTY)      # WLED fixtures' idle Aurora, with a slow breathe
        i = int(x)
        c = lerp(PARTY[i], PARTY[(i + 1) % len(PARTY)], x - i)
        v = 0.22 + 0.1 * math.sin(ctx["t"] * 2 * math.pi / 7)
        out.update(r=float(c[0]) * v, g=float(c[1]) * v, b=float(c[2]) * v)
    elif s == "INTRO":
        colour(layer(ctx, place(role), 0.5), 0.8, 0.12 + 0.6 * min(1.0, hit(ctx, role) * drive(ctx)))
    elif s in ("GROOVE", "OUTRO", "PAUSED"):
        fade = {"OUTRO": 0.8, "PAUSED": 0.25}.get(s, 1.0)
        kick = 0.0 if s == "PAUSED" else hit(ctx, role)
        v = (0.18 + 0.82 * min(1.0, kick * drive(ctx))) * fade
        colour(layer(ctx, place(role), 0.5), 1.0, v)
        if bwb == 1:                                  # bar accent: push toward white
            out["w"] = 0.6 * kick * fade
            for k in ("r", "g", "b"):
                out[k] = min(1.0, out[k] + 0.35 * kick * fade)
    elif s == "BREAKDOWN":
        sp, en = ctx.get("section_progress", 0.0), ctx.get("energy", 0.5)
        mixc = 0.5 - 0.5 * math.cos(2 * math.pi * beat / 8)         # key -> complement over 2 bars
        half = 0.5 + 0.5 * math.cos(math.pi * (beat % 2))           # half-time breathe (peaks on 1 and 3)
        v = (0.10 + 0.25 * en + 0.2 * sp) * (0.45 + 0.55 * half)
        colour(hue + 0.5 * mixc, 0.55 + 0.4 * sp, v)
        out["uv"] = 0.4 + 0.3 * half
    elif s in ("BUILD", "HOLD") and ctx.get("build_style", "rise") != "rise":
        h, sa, v = (float(a) for a in build_field(ctx, place(role), 0.5))
        colour(h, sa, v)
        out["w"] = (1 - sa) * v                       # whiter as it desaturates
    elif s in ("BUILD", "HOLD"):
        p = ctx["progress"]
        rate = 1 if p < 0.5 else 2 if p < 0.75 else 4 if p < 0.9 else 8
        on = ((beat * rate) % 1.0) < 0.45
        v = (0.3 + 0.7 * p) if on else 0.0
        colour(hue, 1.0 - 0.85 * p, v)                # desaturates toward white as it builds
        out["w"] = p * v
    elif s == "PREDROP":
        pass                                          # blackout, the inhale
    elif s == "DROP":
        sd = ctx["since_drop"]
        if sd < 0.25:
            out.update(r=1.0, g=1.0, b=1.0, w=1.0)
        else:
            strobe = sd < 4 and ((sd * 2) % 1.0) > 0.5
            v = 0.0 if strobe else 0.35 + 0.65 * (kick if sd < 4 else hit(ctx, role))
            colour(pal(ctx, int(sd)), 1.0, v)
            out["uv"] = 0.3
    out["r"], out["g"], out["b"] = unyellow_rgb([out["r"], out["g"], out["b"]]).tolist()
    return out


# ---------------------------------------------------------------- mask eyes (worn by the DJ)

WHITE_LED = np.array([1.0, 0.93, 0.82], np.float32)


def eyes(ctx, n, role, state):
    """The DJ's mask: two eyes of 3 LEDs, lit together. They follow the par can's wash (same colour,
    same hits, white flash on the drop), with its white folded into RGB; amber and UV are left out.
    Returns (n, 3) floats 0..1."""
    v = par(ctx, role, state)
    rgb = np.array([v["r"], v["g"], v["b"]], np.float32) * v["dimmer"] + WHITE_LED * v["w"]
    return np.tile(np.clip(rgb, 0.0, 1.0), (n, 1)).astype(np.float32)


# ---------------------------------------------------------------- breakdown looks

def _eighth_ticks(state, beat):
    """Number of eighth-note boundaries crossed since the last frame (0, 1, occasionally 2)."""
    e = int(beat * 2)
    last = state.get("eighth")
    state["eighth"] = e
    return 0 if last is None or e < last or e - last > 4 else e - last


def strip_breakdown(ctx, n, role, state, x, beat):
    """Less is more (the tube diffuser makes a few LEDs glow): near-dark base, sparkles locked to
    the eighth notes (brighter on the beat), and one slow droplet per bar. Density and brightness
    rise with section progress so the breakdown leans into the build."""
    hue, sp, en = ctx["hue"], ctx.get("section_progress", 0.0), ctx.get("energy", 0.5)
    flip = 0.5 if role.get("flip") else 0.0
    half = 0.5 + 0.5 * math.cos(math.pi * (beat % 2))
    # Faint ember: a single soft glow near the bottom, breathing in half-time.
    ember = np.exp(-x * 4) * (0.08 + 0.12 * en + 0.08 * sp) * (0.4 + 0.6 * half)
    out = hsv(hue - 0.06 + flip * 0.25, 0.7, 1.0)[None, :] * ember[:, None]

    # Sparkles spawned exactly on eighth-note boundaries; decay measured in beats.
    sparks = state.setdefault("sparks", [])              # [pixel, spawn beat, strength]
    e = int(beat * 2)
    last = state.get("eighth")
    if last is not None and 0 < e - last <= 2:
        on_beat = e % 2 == 0
        count = (2 + int(3 * sp)) * (2 if on_beat else 1)
        strength = (0.9 if on_beat else 0.55) * (0.6 + 0.4 * en)
        for px in rng.integers(0, n, size=count):
            sparks.append([int(px), e / 2.0, strength])
    state["eighth"] = e
    # Keep sparks spawned in the last half beat; drop any 'from the future' after a jump back (loop, hot cue).
    sparks[:] = [sk for sk in sparks if 0.0 <= beat - sk[1] < 0.5]
    for px, b0, st in sparks:
        v = st * math.exp(-min(50.0, max(0.0, beat - b0)) * 9)
        c = hsv(hue + 0.5 * ((px * 7) % 3 == 0) + flip * 0.2, 0.25, v)
        out[px] = np.maximum(out[px], c)

    # One droplet per bar, launched on the downbeat, falling over about 2 beats.
    bar_start = int((beat - 1) // 4)
    if state.get("drop_bar") != bar_start:
        state["drop_bar"] = bar_start
        state.setdefault("drops", []).append([bar_start * 4 + 1 + role.get("index", 0) * 0.5, hue + 0.5 + flip * 0.2])
    idx = np.arange(n, dtype=np.float32) / max(1, n - 1)
    keep = []
    for b0, dh in state.get("drops", []):
        pos = 1.05 - (beat - b0) * (0.5 + 0.3 * sp)
        if beat < b0:
            if b0 - beat < 4:          # launching this bar; anything further ahead is from before a jump back
                keep.append([b0, dh])
            continue
        if pos < -0.3:
            continue
        keep.append([b0, dh])
        dist = idx - pos
        tail = np.exp(-np.abs(dist) * np.where(dist >= 0, 22.0, 80.0)) * (0.4 + 0.4 * sp)
        out = np.maximum(out, hsv(dh, 0.4, 1.0)[None, :] * tail[:, None])
    state["drops"] = keep
    return out


def panel_breakdown(ctx, w, h, role, state, X, Y, beat):
    """Two-colour plasma breathing in half-time, slanted rain streaks spawned on eighth notes,
    and a bright sweep across the panel every 2 bars."""
    hue, sp, en = ctx["hue"], ctx.get("section_progress", 0.0), ctx.get("energy", 0.5)
    half = 0.5 + 0.5 * math.cos(math.pi * (beat % 2))
    t = beat / 4
    plasma = 0.5 + 0.25 * np.sin(X / 11 + t * 1.3) + 0.25 * np.sin((X + Y * 3) / 17 - t * 0.9)
    level = (0.1 + 0.2 * en + 0.12 * sp) * (0.55 + 0.45 * half)
    out = hsv(hue - 0.05 + 0.5 * plasma * (0.35 + 0.3 * sp), 0.5 + 0.35 * sp, level * (0.5 + 0.8 * plasma))

    streaks = state.setdefault("streaks", [])           # [x, y, speed rows/beat, hue]
    for _ in range(_eighth_ticks(state, beat)):
        for _k in range(1 + int(3 * sp)):
            streaks.append([rng.random() * w, -2.0, 10 + 8 * rng.random() + 10 * sp, hue + 0.2 * rng.random()])
    dt = max(0.0, min(0.2, beat - state.get("last_beat", beat))) or 0.02
    state["last_beat"] = beat
    for st in streaks:
        st[1] += st[2] * dt
        st[0] += st[2] * dt * 0.35                       # slant
    streaks[:] = [st for st in streaks if st[1] < h + 6]
    for sx, sy, _, sh in streaks:
        d = sy - Y                                       # trail above the head
        across = np.abs(X - (sx - d * 0.35))
        m = np.where((d >= 0) & (d < 6) & (across < 0.8), np.exp(-d / 2.2), 0.0) * (0.45 + 0.4 * sp)
        out = np.maximum(out, hsv(sh, 0.3, 1.0) * m[..., None])
    # Sweep every 2 bars.
    ph = (beat / 8) % 1.0
    band = np.exp(-np.abs(X - ph * (w + 40) + 20) / 5) * (0.25 + 0.35 * sp)
    out = np.maximum(out, hsv(hue + 0.5, 0.4, 1.0) * band[..., None])
    return out
