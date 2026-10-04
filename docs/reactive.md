# Audio-reactive drivers

Sketches whose features are driven by *frequency* and *tempo* together: the kick's low end punches one thing, the hats tick another, the chords swell a third, each on its own loop length.

After pwnisher's [How I Create Audio-Reactive Art](https://www.youtube.com/watch?v=12J2XH2UxDc) (Touch Designer crash course, Aug 2025). `sisyphus` is the first sketch built on it; `cathedral` and `inkwell` followed.

## What carries over from the video

He builds one look and then bolts a handful of named **moves** onto it — Swell, Flip, Pulse, Shift, Colours, Float — and each move is one driver wired to one parameter:

| In the video | Here |
|---|---|
| Swell: an **LFO CHOP** on a size parameter | a loop of *N* beats, shaped as a swell |
| Flip / Pulse: a **KeyboardIn CHOP** or MIDI note fires an event | a frequency band crossing into a beat slot |
| Shift: a slow **Noise** value wandering | a slow loop re-rolling a random value |
| Playing it live on a MIDI controller | the track itself plays it |

Two things are worth stealing beyond the operators. First, **the moves are few and named** — six knobs you can hold in your head and perform, not a routing matrix. Second, **each move runs at its own speed**, so they drift in and out of phase and the picture never looks like one metronome. That's what makes an 8-bar swell under a 4/4 punch read as music rather than as a strobe.

What we drop: he triggers by hand (keyboard, MIDI, game controller). We trigger from the track, because the brain already knows the beat grid and the frequency content.

## What we already have to drive it with

No new service, no FFT, no extra plumbing. Every sketch already gets these (see [`render.js`](../brain/projector/web/render.js) `COMMON`):

| Source | What it is |
|---|---|
| `wave(beat)` | `(height, bass, mids, highs)`, each 0..1, at any beat of the **live track**, from the rekordbox colour waveform, at full detail: one sample per rekordbox frame (about 70 a beat at 128 BPM). |
| `u_beat` | the track's beat position, smooth and fractional |
| `u_bwb` | beat within the bar, 1..4 — gives us the downbeat |
| `u_frac`, `kick()` | position within the beat; `kick()` is 1 on the beat, decaying |
| `u_energy`, `u_scene`, `u_sp` | the show engine's energy, section and progress through it |

So `wave().y` **is** the kick's low end, `wave().w` **is** the hats, `wave().z` **is** the chords and mids. See [visuals.md](visuals.md#the-live-tracks-waveform).

Two honest limits. It's the **analysed** waveform of the track as rekordbox measured it, not live audio off the mixer — so a bass kill, a filter sweep or a fader move doesn't show up in it, and the level is the recording's, not the room's. And it's per beat-grid, so the finest event it resolves is a 32nd note. In exchange it's rock solid through tempo changes, it's identical on every surface with no drift, and it can **read ahead**: `wave(u_beat + 16.0)` is four bars from now, so a visual can start a swell before the chord actually lands.

## The model: band × loop × shape × depth

One driver = four numbers. Everything below is one slot.

```
      BAND            LOOP             SHAPE            DEPTH
   which frequency  how often it    what it does     how much it
   decides how      fires           between fires    moves the picture
   hard it hits
```

Band and loop are the pairing the whole thing turns on: **the loop says *when*, the band says *how hard*.** Set the loop to a bar and the band to kick, and you get a thump on every downbeat, hard on the loud ones and barely there on the quiet ones. Set the loop to 8 bars and the band to mids, and the picture opens up on whichever chord change happens to be loudest.

### Bands

| Value | Band | Reads |
|---|---|---|
| 0 | **Off** | always 1.0 — not gated by sound, pure tempo (the video's LFO) |
| 1 | **Kick** | `wave().y` — the low end |
| 2 | **Chords** | `wave().z` — the mids |
| 3 | **Hats** | `wave().w` — the highs |
| 4 | **Everything** | `wave().x` — overall level |
| 5 | **Energy** | `u_energy` — the show engine's read on the section |

### Loops

Bar-aligned, so anything a bar or longer lands on the downbeat.

| Value | Loop | Beats |
|---|---|---|
| 0 | 1/2 beat (8ths) | 0.5 |
| 1 | every beat (4/4) | 1 |
| 2 | 1 bar | 4 |
| 3 | 2 bars | 8 |
| 4 | 4 bars | 16 |
| 5 | 8 bars | 32 |
| 6 | 16 bars | 64 |

### Shapes

What the driver does across one loop.

| Value | Shape | Curve |
|---|---|---|
| 0 | **Follow** | tracks the band continuously — no trigger, just the level |
| 1 | **Punch** | snaps to the band's level at the trigger, decays away |
| 2 | **Ramp** | climbs 0 → 1 across the loop, then drops |
| 3 | **Swell** | eases 0 → 1 → 0 across the loop |
| 4 | **Gate** | hard on for the first half of the loop, off for the second |
| 5 | **Step** | holds one random value, re-rolls every loop |

Follow + kick is a woofer cone. Punch + kick + 4/4 is a strobe on the beat. Swell + chords + 8 bars is a breath. Step + off + 16 bars is the video's slow noise wander. Gate + hats + 8ths is a shutter.

## The dictionary: three slots, fixed jobs

Every reactive sketch exposes the **same three slots with the same ids**, and each sketch documents what its three are wired to. Learn it once and every sketch works the same way — that's the point.

| Slot | Job | Wired to something that is… | Typical |
|---|---|---|---|
| **A — Hit** | short, sharp, per-event | instant and forgiving of being spammed | scale punch, flash, shake, RGB split |
| **B — Move** | continuous motion | smooth, cumulative | rotation, drift, scroll, warp, wobble |
| **C — Change** | structural, slow | expensive or jarring to change often | re-roll the layout, shift the palette, switch mode, reveal |

Twelve parameters in one **Reactivity** group, always identical:

```json
{"name": "Reactivity", "params": [
  {"id": "aband",  "label": "A Hit · band (0 off, 1 kick, 2 chords, 3 hats, 4 all, 5 energy)", "min": 0, "max": 5, "step": 1, "default": 1},
  {"id": "aloop",  "label": "A Hit · loop (0 ½beat, 1 beat, 2 bar, 3 2bar, 4 4bar, 5 8bar, 6 16bar)", "min": 0, "max": 6, "step": 1, "default": 1},
  {"id": "ashape", "label": "A Hit · shape (0 follow, 1 punch, 2 ramp, 3 swell, 4 gate, 5 step)", "min": 0, "max": 5, "step": 1, "default": 1},
  {"id": "aamt",   "label": "A Hit · amount", "min": 0, "max": 1, "step": 0.01, "default": 0.6},

  {"id": "bband",  "label": "B Move · band",  "min": 0, "max": 5, "step": 1, "default": 3},
  {"id": "bloop",  "label": "B Move · loop",  "min": 0, "max": 6, "step": 1, "default": 0},
  {"id": "bshape", "label": "B Move · shape", "min": 0, "max": 5, "step": 1, "default": 0},
  {"id": "bamt",   "label": "B Move · amount","min": 0, "max": 1, "step": 0.01, "default": 0.4},

  {"id": "cband",  "label": "C Change · band",  "min": 0, "max": 5, "step": 1, "default": 2},
  {"id": "cloop",  "label": "C Change · loop",  "min": 0, "max": 6, "step": 1, "default": 5},
  {"id": "cshape", "label": "C Change · shape", "min": 0, "max": 5, "step": 1, "default": 3},
  {"id": "camt",   "label": "C Change · amount","min": 0, "max": 1, "step": 0.01, "default": 0.5}
]}
```

Those defaults are the house sound: kick punching on every beat, hats shimmering in 8ths, chords swelling over 8 bars. A sketch keeps its own look parameters (size, colour, detail) in its own groups on top, same as every sketch today.

## The code

One block in `COMMON` in [`render.js`](../brain/projector/web/render.js), next to `kick()`. No new uniforms — it's built from what's already there, so every sketch and the projector's built-in content get it for free.

```glsl
// --- Audio-reactive drivers (docs/reactive.md) ------------------------------
// One frequency band of the live track, 0..1. 0 = off, and off means 1.0:
// not gated by sound, so the shape runs on tempo alone.
float band(float b, float beat) {
  if (b < 0.5) return 1.0;
  vec4 w = wave(beat);
  if (b < 1.5) return w.y;          // kick / low end
  if (b < 2.5) return w.z;          // chords / mids
  if (b < 3.5) return w.w;          // hats / highs
  if (b < 4.5) return w.x;          // everything
  return u_energy;                  // the show engine's energy
}

// Loop length in beats: half a beat, a beat, then 1, 2, 4, 8, 16 bars.
float loopBeats(float r) {
  if (r < 0.5) return 0.5;
  if (r < 1.5) return 1.0;
  if (r < 2.5) return 4.0;
  if (r < 3.5) return 8.0;
  if (r < 4.5) return 16.0;
  if (r < 5.5) return 32.0;
  return 64.0;
}

// The beat counter shifted so that every downbeat is a multiple of 4, which puts
// every loop of a bar or longer on the "1" rather than wherever the track started.
float barBeat() { return u_beat - mod(floor(u_beat) - (u_bwb - 1.0), 4.0); }

// A driver, 0..1: the loop says when it fires, the band says how hard.
float drive(float bd, float rate, float shape, float amt) {
  float L  = loopBeats(rate);
  float bb = barBeat();
  float ph = fract(bb / L);                                     // 0..1 through this loop
  float n  = floor(bb / L);                                     // which loop we're in
  // How loud the band was when the loop fired. Two samples over the first beat, so a long
  // loop isn't decided by whatever happened to be in one 32nd note.
  float hit = max(band(bd, n * L + 0.15), band(bd, n * L + 0.55));
  float v;
  if      (shape < 0.5) v = band(bd, u_beat);                   // follow
  else if (shape < 1.5) v = hit * exp(-5.0 * ph * max(L, 1.0)); // punch
  else if (shape < 2.5) v = hit * ph;                           // ramp
  else if (shape < 3.5) v = hit * (0.5 - 0.5 * cos(6.2831 * ph));  // swell
  else if (shape < 4.5) v = hit * step(ph, 0.5);                // gate
  else                  v = hit * hash(vec2(n, bd));            // step
  return amt * clamp(v, 0.0, 1.0);
}
```

A sketch then reads its three slots in one line each:

```glsl
uniform float p_aband, p_aloop, p_ashape, p_aamt,
              p_bband, p_bloop, p_bshape, p_bamt,
              p_cband, p_cloop, p_cshape, p_camt;

vec3 content(vec2 uv) {
  float A = drive(p_aband, p_aloop, p_ashape, p_aamt);   // Hit    -> scale punch
  float B = drive(p_bband, p_bloop, p_bshape, p_bamt);   // Move   -> spin
  float C = drive(p_cband, p_cloop, p_cshape, p_camt);   // Change -> palette
  ...
}
```

`drive()` is four texture lookups at worst and runs per pixel; on a scene using all three slots that's fine, but a sketch that wants a driver in a loop should hoist the three calls to the top of `content()` and pass the values down.

## Presets

Ship the combinations as named presets so a slot config is one tap, not twelve slider moves.

## Gotcha: band 0 is not "off"

Band 0 means *not gated by sound* — `band()` returns 1.0, so the driver runs on tempo alone at full strength. To actually silence a slot, set its **amount** to 0. Setting the band to 0 does the opposite of what the label suggests.

## Gotcha: a driver must not be able to empty the picture

A slot's amount is a range, not a nudge, and the sketch has to be worth looking at across all of
it — including the loudest hit in the track, which is the one the audience sees. `cathedral`
learned this the hard way: B Move was wired straight to the fold angle of its fractal, and about
a seventh of a turn on that angle throws the fractal apart, so on the loud hats the picture went
black. The fix was to map the slider and the driver onto the window of the parameter that always
builds something, rather than onto its whole mathematical range.

So before wiring a slot to a parameter, sweep that parameter end to end and look at it. Anything
with a dead zone gets remapped, not just given a smaller amount — a smaller amount only makes the
blackout rarer, which is worse than making it reliable.

The same habit catches parameters no driver is anywhere near. `wormhole`'s **Mirror** folds the
angle into a wedge of `TAU/(2m)`, but the word lookup was still dividing by a whole `TAU` — so
every setting above 1 quietly sampled only the first `1/(2m)` of the word, a quarter of it at
Mirror 2. It read as the letterforms falling apart, which looked enough like "kaleidoscopes are
just hard on type" to be written off; it was arithmetic, and the fix was one term. A fold, a `mod`
or a `clamp` narrows the domain of everything downstream of it, and nothing warns you.

## The one exception: Hz

Everything in this rig is in cycles per beat, and that is the rule. There is exactly one place it
is broken on purpose. A parameter's **automation** (see [visuals-live.md](visuals-live.md)) has a
**Hz** toggle: with it on, that one LFO free-runs on wall time (`u_time`) instead of the beat.

It is there because some movement should not be musical — a hue drifting over a minute and a half,
a slow wander that would look mechanical if it locked to the bar. Turning it on is a decision to
come off the grid, so it is labelled on the control and it is off by default.

Note what it does **not** do. A sketch's own speed parameters (the ones marked `"kind": "rate"`,
like `speed` in `rings.json`) are multiplied by `u_beat` inside the shader, so they cannot free-run
without changing the shader; they snap to note values and stay on the beat. Hz applies to the
automation LFOs only, which are evaluated in `render.js` where wall time is to hand.

## Testing at home

`wave()` falls back to the looped demo track when no deck is live, so all of this can be dialled in on a laptop. For a real track's bands, capture one on the rig: `python3 brain/visuals/tools/capture_wave.py http://<brain IP>:8080`. Note that `u_energy` and `u_scene` only move when showbrain is running, so bands 5 and the section-driven looks stay flat at home.
