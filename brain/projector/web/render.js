// Sektor5 projection renderer: shared by the projector output (index.html) and the
// editor's live preview (edit.html).
//
// Each surface is a quad given by four corners in normalised screen coordinates
// (0..1, y down), or a triangle given by three (apex, base right, base left: for the faces of a
// pyramid). Content is drawn per pixel through the inverse homography of that quad, so it lands
// with correct perspective on angled surfaces; a triangle shows the content's square cropped to
// the triangle, apex at the top centre (an affine map, exact for a flat face). A diamond (four corners:
// top, right, bottom, left; "shape": "diamond") shows the content's square upright and centred, cropped to
// the diamond: the square's edge midpoints land on its corners. Masks are black
// polygons drawn on top. All content is beat-locked to the show engine's state.
// Surfaces can have rounded corners and a border band drawn over their content.
// Content "gen" is a generative sketch from the visuals service (:8110): the live one (whatever the
// Visuals page shows), or the surface's own "sketch" (+ "preset"), fetched and compiled once.
// With several projectors, each surface and mask belongs to one; draw() renders one projector.
// When the live sketch or its preset changes, the service can ask for a transition, synced to the
// beat: surfaces showing the live sketch hand over through it (setSketch).
// Sketches can also read the live track's waveform by beat: wave(beat) (see COMMON).

"use strict";

const SCENES = { IDLE: 0, INTRO: 1, GROOVE: 2, BREAKDOWN: 3, BUILD: 4, HOLD: 5, PREDROP: 6, DROP: 7, OUTRO: 8, PAUSED: 9 };

// ---------------------------------------------------------------- live show state

// Updates arrive ~20x/s with network jitter, so the displayed beat doesn't snap to each one:
// it runs at the track's tempo and eases towards the reported position (at most 10% faster
// or slower), only jumping on a seek or track change.
//
// Timing: showbrain stamps each state (s.t, wall clock) and its beat is already s.lead_ms ahead, for the
// LEDs' Wi-Fi delay. The page undoes that lead and counts the state's age from the stamp, so `lead`
// (the layout's lead_ms) is purely this projector's own output delay (GPU, HDMI, the projector's
// processing): calibrate it with the test card, whose centre flashes on the beat. A page whose clock
// disagrees with showbrain's by more than a second (another machine without NTP) counts from arrival.
class ShowClock {
  constructor() { this.s = null; this.at = 0; this.age = 0; this.sbLead = 0; this.lead = 60; this.titleVer = 0; this.title = ""; this.b = null; this.last = 0; }
  update(s) {
    this.s = s; this.at = performance.now();
    const age = s && s.t ? Date.now() - s.t * 1000 : NaN;
    this.age = Number.isFinite(age) && age > -50 && age < 1000 ? Math.max(0, age) : 0;
    this.sbLead = s && Number.isFinite(s.lead_ms) ? s.lead_ms : 0;
    const t = s && s.title ? s.title : "";
    if (t !== this.title) { this.title = t; this.titleVer++; }
  }
  // Everything the shaders need, extrapolated to "now + lead".
  frame(now) {
    const s = this.s;
    const dtBeats = s && s.bpm ? ((now - this.at + this.age - this.sbLead + this.lead) / 1000) * s.bpm / 60 : 0;
    if (!s || !s.live || !s.bpm) {
      this.b = null;
      const b = now / 500;                                  // 120 BPM idle clock
      return { scene: SCENES.IDLE, beat: b, frac: b % 1, bwb: 1 + (Math.floor(b) % 4), bar: 0, hue: (now / 60000) % 1,
               progress: 0, since: 0, energy: 0.3, sp: 0, todrop: -1, drop: null };
    }
    const target = (s.beat || 0) + dtBeats, rate = s.bpm / 60;
    const dt = Math.min(0.1, Math.max(0, (now - this.last) / 1000));
    this.last = now;
    if (this.b === null || Math.abs(target - this.b) > 4) this.b = target;
    else {
      const pred = this.b + dt * rate, lim = 0.1 * rate * dt;
      this.b = pred + Math.max(-lim, Math.min(lim, (target - pred) * Math.min(1, dt / 0.4)));
    }
    const beat = this.b;
    const bwb = ((((s.bwb || 1) - 1) + Math.floor(beat) - Math.floor(s.beat || 0)) % 4 + 4) % 4 + 1;
    const scene = SCENES[s.scene] ?? SCENES.GROOVE;
    return { scene, beat, frac: ((beat % 1) + 1) % 1, bwb, bar: s.bar || 0, hue: s.hue || 0,
             progress: s.progress || 0, since: scene === SCENES.DROP ? (s.since_drop || 0) + dtBeats : 0,
             energy: s.energy ?? 0.5, sp: s.section_progress || 0,
             // The next drop showbrain predicts from the track's analysis (beats to it; -1 = none known).
             todrop: s.beats_to_drop == null ? -1 : Math.max(s.beats_to_drop - dtBeats, -1),
             drop: s.beats_to_drop == null ? null : Math.round((s.beat || 0) + s.beats_to_drop) };
  }
}

// ---------------------------------------------------------------- parameter automation

// Any sketch parameter can move on its own between a range the user sets. The control page
// stores the settings; the value itself is worked out here, every frame, from the beat. That
// keeps it locked to the music, costs nothing on the network, needs no shader recompile, and
// means the projector and the preview arrive at the same number without talking to each other.
//
// rate is in cycles per beat like every other speed in the rig: a 1/4 note is one beat, so
// rate 1. hz: true is the one intentional exception and free-runs on wall time instead --
// see docs/reactive.md. Shapes: 0 sine, 1 triangle, 2 saw up, 3 saw down, 4 square,
// 5 random step, 6 smooth random.
//
// duty (0..1, default 0.5) is how much of a square's cycle is spent at the top. Down at 0.15 it
// is a strobe rather than a chop, which is what the Launchpad's STROBE pad wants.
function autoHash(n) { const x = Math.sin(n * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); }
function autoEval(a, beat, inBar, time) {
  const t = (a.hz ? time : (a.retrig ? inBar : beat)) * (a.rate || 0) + (a.phase || 0);
  const x = t - Math.floor(t), n = Math.floor(t);
  let v;
  switch (a.shape | 0) {
    case 1: v = 1 - Math.abs(2 * x - 1); break;
    case 2: v = x; break;
    case 3: v = 1 - x; break;
    case 4: v = x < (a.duty === undefined ? 0.5 : a.duty) ? 1 : 0; break;
    case 5: v = autoHash(n); break;
    case 6: { const u = x * x * (3 - 2 * x); v = autoHash(n) * (1 - u) + autoHash(n + 1) * u; break; }
    default: v = 0.5 - 0.5 * Math.cos(6.2831853 * x);
  }
  const lo = a.lo, hi = a.hi;
  return lo + (hi - lo) * v;
}

// ---------------------------------------------------------------- homography

// Unit square (0,0),(1,0),(1,1),(0,1) -> quad corners. Returns 3x3 row-major.
function squareToQuad(c) {
  const [x0, y0] = c[0], [x1, y1] = c[1], [x2, y2] = c[2], [x3, y3] = c[3];
  const dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
  const dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
  let g = 0, h = 0;
  if (Math.abs(dx3) > 1e-9 || Math.abs(dy3) > 1e-9) {
    const det = dx1 * dy2 - dx2 * dy1 || 1e-9;
    g = (dx3 * dy2 - dx2 * dy3) / det;
    h = (dx1 * dy3 - dx3 * dy1) / det;
  }
  return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
          y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
          g, h, 1];
}

// A triangle surface: the content square's (0.5, 0), (1, 1), (0, 1) -> its apex, base right, base left.
function squareToTri(c) {
  const [a, r, l] = c, ex = r[0] - l[0], ey = r[1] - l[1];              // (1, 0) in the square
  const fx = 0.5 * ex - (a[0] - l[0]), fy = 0.5 * ey - (a[1] - l[1]);   // (0, 1)
  return [ex, fx, l[0] - fx, ey, fy, l[1] - fy, 0, 0, 1];
}
// A diamond: the content square's edge midpoints (0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5) -> its top, right,
// bottom and left corners (a homography, so it keeps perspective on an angled face).
const DIAMOND_IN_SQUARE = invert3Lazy();
function invert3Lazy() { let m = null; return () => m || (m = invert3(squareToQuad([[0.5, 0], [1, 0.5], [0.5, 1], [0, 0.5]]))); }
function mul3(a, b) {
  const o = new Array(9);
  for (let r = 0; r < 3; r++) for (let c = 0; c < 3; c++) o[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
  return o;
}
const squareToDiamond = c => mul3(squareToQuad(c), DIAMOND_IN_SQUARE());
const isDiamond = s => s.shape === "diamond" && s.corners.length === 4;
const surfaceMatrix = (c, shape) => c.length === 3 ? squareToTri(c) : shape === "diamond" ? squareToDiamond(c) : squareToQuad(c);

function invert3(m) {
  const [a, b, c, d, e, f, g, h, i] = m;
  const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
  const det = a * A + b * B + c * C || 1e-12;
  return [A / det, -(b * i - c * h) / det, (b * f - c * e) / det,
          B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
          C / det, -(a * h - b * g) / det, (a * e - b * d) / det];
}

// Row-major 3x3 -> column-major Float32Array for uniformMatrix3fv.
const colMajor = m => new Float32Array([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);

function quadSize(c, W, H, shape) {
  const d = (p, q) => Math.hypot((p[0] - q[0]) * W, (p[1] - q[1]) * H);
  if (c.length === 3) return [d(c[1], c[2]), d(c[0], [(c[1][0] + c[2][0]) / 2, (c[1][1] + c[2][1]) / 2])];   // base, height
  if (shape === "diamond") return [d(c[3], c[1]), d(c[0], c[2])];                                             // the diagonals
  return [(d(c[0], c[1]) + d(c[3], c[2])) / 2, (d(c[0], c[3]) + d(c[1], c[2])) / 2];
}
function quadAspect(c, W, H) {
  const [w, h] = quadSize(c, W, H);
  return h > 1 ? w / h : 1;
}

// ---------------------------------------------------------------- shaders

// Each surface is drawn as its bounding box (u_box, in clip space), not the whole screen.
const VERT = `attribute vec2 a; uniform vec4 u_box;
void main() { gl_Position = vec4(mix(u_box.xy, u_box.zw, a * 0.5 + 0.5), 0.0, 1.0); }`;

const COMMON = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 u_res; uniform mat3 u_Hinv; uniform float u_aspect;
uniform float u_beat, u_frac, u_bwb, u_bar, u_hue, u_scene, u_progress, u_since, u_energy, u_sp;
// u_todrop: beats to the next drop showbrain predicts (-1 = none known). u_cbeat: the beat a sketch's
// climax cycle runs on: u_beat, shifted so the sketch's climax lands on the drop (see MapRenderer._cbeat).
uniform float u_todrop, u_cbeat;
uniform float u_opacity, u_bright, u_sel, u_time;
uniform float u_radius, u_border, u_bbright, u_bsat, u_bpulse;
uniform float u_tri;   // 1: a triangle surface (apex at the top centre of the square)
uniform float u_dia;   // 1: a diamond surface (the square's edge midpoints on its corners)
uniform float u_px;   // one output pixel in surface units (surface height = 1), for anti-aliasing
uniform sampler2D u_tex;
// The live track's waveform, resampled per beat by the visuals service (trackwave.py).
// u_wv = (texture width, height, samples per beat, beats; 0 = none). u_wloop = 1 for the demo/sample.
uniform sampler2D u_wave; uniform vec4 u_wv; uniform float u_wloop;
vec4 waveTexel(float i) {
  return texture2D(u_wave, (vec2(mod(i, u_wv.x), floor(i / u_wv.x)) + 0.5) / u_wv.xy);
}
// (height, bass, mids, highs), each 0..1, at a beat position in the track (1 = its first beat).
vec4 wave(float beat) {
  float n = u_wv.w * u_wv.z;
  if (n < 1.0) return vec4(0.0);
  float i = (beat - 1.0) * u_wv.z;
  if (u_wloop > 0.5) i = mod(i, n);
  if (i < 0.0 || i > n - 1.0) return vec4(0.0);
  float i0 = floor(i);
  return mix(waveTexel(i0), waveTexel(min(i0 + 1.0, n - 1.0)), i - i0);
}
// Words typed on the Visuals page, drawn to a texture by the page and handed to every sketch.
// Eight rows of 1/8 the height, one word each, white on black, each word scaled to fit its row
// with its letterforms intact. u_textn says how many rows are actually in use.
uniform sampler2D u_text; uniform float u_textn;
// Coverage of word ROW at uv, where uv is 0..1 across that word's own row and uv.y = 0 is the
// top of it. Off the edge of the word it is 0, so a sketch can lay it anywhere without clipping.
float word(vec2 uv, float row) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 0.0;
  float k = mod(floor(row + 0.5), max(1.0, u_textn));
  return texture2D(u_text, vec2(uv.x, (k + uv.y) * 0.125)).r;
}
vec3 hsv(float h, float s, float v) {
  vec3 k = clamp(abs(mod(h * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
  return v * mix(vec3(1.0), k, s);
}
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float kick() { return exp(-6.0 * u_frac); }
// --- Audio-reactive drivers (docs/reactive.md) ------------------------------
// One frequency band of the live track, 0..1. 0 = off, and off means 1.0: not gated
// by sound, so the shape below runs on tempo alone (the LFO case).
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
// The beat counter shifted so every downbeat is a multiple of 4, which puts loops of a
// bar or longer on the "1" instead of wherever the track's first beat happened to fall.
float barBeat() { return u_beat - mod(floor(u_beat) - (u_bwb - 1.0), 4.0); }
// A driver, 0..1: the loop says when it fires, the band says how hard.
float drive(float bd, float rate, float shape, float amt) {
  float L = loopBeats(rate), bb = barBeat();
  float ph = fract(bb / L);                                        // 0..1 through this loop
  float n = floor(bb / L);                                         // which loop we are in
  // How loud the band was when the loop fired. Two samples over the first beat, so a long
  // loop isn't decided by whatever happened to be in one 32nd note.
  float hit = max(band(bd, n * L + 0.15), band(bd, n * L + 0.55));
  float v;
  if      (shape < 0.5) v = band(bd, u_beat);                      // follow
  else if (shape < 1.5) v = hit * exp(-5.0 * ph * max(L, 1.0));    // punch
  else if (shape < 2.5) v = hit * ph;                              // ramp
  else if (shape < 3.5) v = hit * (0.5 - 0.5 * cos(6.2831 * ph));  // swell
  else if (shape < 4.5) v = hit * step(ph, 0.5);                   // gate
  else                  v = hit * hash(vec2(n, bd));               // step
  return amt * clamp(v, 0.0, 1.0);
}
// 0 far from a drop, rising over the 16 beats before one to 1 on it, easing off over the 8 after.
float dropArc() {
  float up = u_todrop >= 0.0 ? 1.0 - clamp(u_todrop / 16.0, 0.0, 1.0) : 0.0;
  float down = abs(u_scene - 7.0) < 0.5 ? exp(-u_since / 8.0) : 0.0;
  return max(up * up, down);
}
vec3 content(vec2 uv);

// ---- Transitions between sketches (see MapRenderer.draw). During one, a surface draws the
// outgoing sketch (u_trole 2) and then the incoming one on top (u_trole 1); either can warp
// its own content coordinates, and the incoming one's alpha is the transition's mask, so no
// render-to-texture is needed. u_tp runs 0..1, u_tdur is the length in beats, u_tseed varies
// each transition. Modes: 0 crossfade, 1 wipe, 2 iris, 3 dissolve, 4 luma, 5 tiles, 6 slices,
// 7 zoom through, 8 swirl, 9 stutter, 10 flash, 11 pixelate. Names start s5t_ to keep clear
// of sketches' own functions.
uniform float u_trole, u_tp, u_tmode, u_tseed, u_tdur;
float s5t_noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
vec2 s5t_rot(vec2 v, float a) { float c = cos(a), s = sin(a); return vec2(c * v.x - s * v.y, s * v.x + c * v.y); }
float s5t_ease(float p) { return p * p * (3.0 - 2.0 * p); }
float s5t_slice(vec2 uv) {             // slices: this band's own progress
  float band = floor(uv.y * 12.0);
  return clamp((u_tp - hash(vec2(band, u_tseed)) * 0.6) / 0.4, 0.0, 1.0);
}
vec2 s5t_uv(vec2 uv) {
  int m = int(u_tmode + 0.5);
  bool inc = u_trole < 1.5;
  float e = s5t_ease(u_tp);
  vec2 A = vec2(u_aspect, 1.0), c = (uv - 0.5) * A;
  if (m == 7) c *= inc ? mix(5.0, 1.0, e) : 1.0 / (1.0 + 5.0 * e * e);        // zoom through
  else if (m == 8) {                                                          // swirl
    float t = inc ? 1.0 - e : e;
    c = s5t_rot(c, (inc ? -1.0 : 1.0) * t * t * 9.0 * max(0.0, 1.0 - length(c)));
  } else if (m == 11) {                                                       // pixelate
    float N = inc ? mix(5.0, 400.0, pow(smoothstep(0.5, 1.0, u_tp), 2.0)) : mix(400.0, 5.0, pow(smoothstep(0.0, 0.5, u_tp), 0.5));
    c = (floor(c * N) + 0.5) / N;
  } else if (m == 6 && inc) {                                                 // slices slide in
    float band = floor(uv.y * 12.0), q = 1.0 - s5t_slice(uv);
    c.x += (hash(vec2(band, u_tseed + 3.1)) > 0.5 ? 1.0 : -1.0) * q * q * u_aspect * 1.05;
  }
  return 0.5 + c / A;
}
// The incoming sketch's coverage (0..1); glow gets any light the transition adds at its edge.
float s5t_mask(vec2 uv, vec2 cuv, vec3 col, inout vec3 glow) {
  int m = int(u_tmode + 0.5);
  float p = u_tp, e = s5t_ease(p);
  vec2 q = (uv - 0.5) * vec2(u_aspect, 1.0);
  vec3 gc = hsv(u_hue, 0.5, 1.0);
  float inside = step(0.0, cuv.x) * step(cuv.x, 1.0) * step(0.0, cuv.y) * step(cuv.y, 1.0);
  if (m == 1) {                                                               // wipe, at one of 8 angles
    float ang = floor(hash(vec2(u_tseed, 1.7)) * 8.0) * 0.7853982;
    vec2 d = vec2(cos(ang), sin(ang));
    float s = dot(q, d) / (0.5 * (abs(d.x) * u_aspect + abs(d.y)));
    float v = mix(-1.1, 1.1, e) - s;
    glow += gc * exp(-abs(v) * 30.0) * 0.9 * sin(3.1416 * p);
    return smoothstep(-0.02, 0.02, v);
  }
  if (m == 2) {                                                               // iris from the centre
    float v = e * 1.1 - length(q) / (0.5 * length(vec2(u_aspect, 1.0)));
    glow += gc * exp(-abs(v) * 25.0) * 0.9 * sin(3.1416 * p);
    return smoothstep(-0.015, 0.015, v);
  }
  if (m == 3) {                                                               // noise dissolve, burning edge
    float n = 0.65 * s5t_noise(q * 5.0 + u_tseed * 7.0) + 0.35 * s5t_noise(q * 13.0 - u_tseed);
    float v = mix(-0.08, 1.08, e) - n;
    glow += mix(vec3(1.0, 0.45, 0.1), vec3(1.0, 0.95, 0.8), exp(-abs(v) * 90.0)) * exp(-abs(v) * 35.0) * 1.2;
    return smoothstep(-0.006, 0.006, v);
  }
  if (m == 4) {                                                               // luma: the bright parts first
    float L = sqrt(dot(col, vec3(0.299, 0.587, 0.114)) / max(u_bright, 0.001));   // lifts dim sketches
    float t = 1.0 - e * 1.25;
    return smoothstep(t - 0.1, t + 0.1, L);
  }
  if (m == 5) {                                                               // tiles grow in at random
    vec2 g = q * 6.0, id = floor(g), f = fract(g) - 0.5;
    float t = s5t_ease(clamp((p - hash(id + u_tseed) * 0.65) / 0.35, 0.0, 1.0));
    float v = t * 0.5 - max(abs(f.x), abs(f.y));
    glow += gc * exp(-abs(v) * 60.0) * 0.6 * step(0.001, t) * step(t, 0.999);
    return smoothstep(-0.02, 0.0, v) * step(0.001, t);
  }
  if (m == 6) return inside * step(0.001, s5t_slice(uv));                    // slices
  if (m == 7) {                                                               // zoom through
    vec2 ed = min(cuv, 1.0 - cuv) * vec2(u_aspect, 1.0);      // distance in from the incoming frame's edge
    float fe = min(ed.x, ed.y), px = u_px * mix(5.0, 1.0, s5t_ease(p));
    glow += gc * exp(-abs(fe) / (3.0 * px)) * 0.8 * (1.0 - p);
    glow += gc * exp(-length(q) * 5.0) * sin(3.1416 * p) * 0.4;
    return smoothstep(-px, px, fe) * smoothstep(0.0, 0.2, p);
  }
  if (m == 8 || m == 11) return smoothstep(0.35, 0.65, p);                   // swirl, pixelate
  if (m == 9) {                                                               // stutter on 16ths
    float slot = floor(p * max(u_tdur, 1.0) * 4.0);
    return max(step(hash(vec2(slot, u_tseed)), p * 1.15 - 0.05), step(0.9, p));
  }
  if (m == 10) {                                                              // white flash, cut on the peak
    float fl = exp(-pow((p - 0.5) / 0.14, 2.0));
    glow += vec3(1.0) * fl * 1.5;
    return max(step(0.5, p), fl);
  }
  return e;                                                                   // crossfade
}

void main() {
  vec2 p = vec2(gl_FragCoord.x / u_res.x, 1.0 - gl_FragCoord.y / u_res.y);
  vec3 q = u_Hinv * vec3(p, 1.0);
  vec2 uv = q.xy / q.z;
  if (q.z <= 0.0 || uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) discard;
  // Rounded-rectangle distance in surface units (height = 1): < 0 inside.
  vec2 hs = vec2(u_aspect, 1.0) * 0.5, sp = (uv - 0.5) * vec2(u_aspect, 1.0);
  float rad = min(u_radius, min(hs.x, hs.y));
  vec2 qd = abs(sp) - hs + rad;
  float sd = length(max(qd, 0.0)) + min(max(qd.x, qd.y), 0.0) - rad;
  if (u_tri > 0.5) {           // and inside the triangle: distance to its sloping edges, in the same units
    sd = max(sd, (abs(sp.x) - 0.5 * u_aspect * (sp.y + 0.5)) / sqrt(1.0 + 0.25 * u_aspect * u_aspect));
    if (sd > 2.0 * u_px) discard;
  }
  if (u_dia > 0.5) {           // inside the diamond: |x| / (w/2) + |y| / (h/2) <= 1, distance in the same units
    vec2 dn = vec2(2.0 / u_aspect, 2.0);
    sd = max(sd, (dot(abs(sp), dn) - 1.0) / length(dn));
    if (sd > 2.0 * u_px) discard;
  }
  float a = smoothstep(0.0, 1.5 * u_px, -sd) * u_opacity;
  vec2 cuv = u_trole > 0.5 ? s5t_uv(uv) : uv;
  vec3 c = content(cuv) * u_bright;
  if (u_trole > 0.5 && u_trole < 1.5) {        // incoming: masked, with the transition's edge light
    vec3 g = vec3(0.0);
    float m = clamp(s5t_mask(uv, cuv, c, g), 0.0, 1.0);
    g *= u_bright;
    c = mix(g, c + g, m);
    a *= max(m, clamp(dot(g, vec3(0.333)), 0.0, 1.0));
  }
  if (u_border > 0.0) {
    float band = smoothstep(-u_border - 1.5 * u_px, -u_border, sd);
    vec3 bc = mix(vec3(1.0), hsv(u_hue, 1.0, 1.0), u_bsat) * u_bbright * mix(1.0, kick(), u_bpulse);
    c = mix(c, bc * u_bright, band);
  }
  if (u_sel > 0.5) c = mix(c, vec3(0.2, 0.9, 1.0), 0.25 * step(-sd, 0.012));
  gl_FragColor = vec4(c, a);
}
`;

const CONTENT = {
  solid: `vec3 content(vec2 uv) { return hsv(u_hue, 0.9, 0.85); }`,

  pulse: `vec3 content(vec2 uv) {
    float accent = u_bwb < 1.5 ? 0.35 : 0.0;
    vec3 c = hsv(u_hue + 0.03 * mod(u_bar, 4.0), 1.0, 0.12 + 0.88 * kick());
    return mix(c, vec3(0.12 + 0.88 * kick()), accent * kick());
  }`,

  tunnel: `vec3 content(vec2 uv) {
    vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
    float r = length(p) + 0.02, a = atan(p.y, p.x);
    float rings = 0.5 + 0.5 * cos((0.6 / r - u_beat * 0.5) * 6.2831);
    float spokes = 0.75 + 0.25 * cos(a * 8.0 + u_beat * 0.8);
    float v = rings * spokes * (0.25 + 0.75 * kick()) * smoothstep(0.0, 0.08, r);
    return hsv(u_hue + r * 0.4 + 0.05 * u_bar, 1.0, v);
  }`,

  bars: `vec3 content(vec2 uv) {
    float n = 16.0, i = floor(uv.x * n), fx = fract(uv.x * n);
    float h = 0.15 + 0.85 * hash(vec2(i, floor(u_beat))) * (0.35 + 0.65 * u_energy);
    h *= 0.45 + 0.55 * kick();
    float lit = step(1.0 - uv.y, h) * step(0.08, fx) * step(fx, 0.92);
    float cap = step(abs((1.0 - uv.y) - h), 0.012) * step(0.08, fx) * step(fx, 0.92);
    return hsv(u_hue + i / (n * 2.0), 1.0, lit * (0.35 + 0.65 * (1.0 - uv.y) / max(h, 0.01))) + cap;
  }`,

  title: `vec3 content(vec2 uv) {
    float t = texture2D(u_tex, uv).r;
    vec3 bg = hsv(u_hue, 1.0, 0.06 + 0.1 * kick());
    return mix(bg, mix(hsv(u_hue, 0.35, 1.0), vec3(1.0), kick() * 0.6), t);
  }`,

  show: `vec3 content(vec2 uv) {
    vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
    float r = length(p), k = kick();
    int sc = int(u_scene + 0.5);
    if (sc == 6) return vec3(0.0);                                  // PREDROP: blackout
    if (sc == 7) {                                                  // DROP
      if (u_since < 0.25) return vec3(1.0);
      float ring = exp(-abs(r - fract(u_since) * 0.9) * 18.0);
      vec3 base = hsv(u_hue + (mod(floor(u_since), 2.0) > 0.5 ? 0.5 : 0.0), 1.0, 0.25 + 0.75 * k);
      return mix(base * 0.6, vec3(1.0), ring * 0.85);
    }
    if (sc == 4 || sc == 5) {                                       // BUILD / HOLD
      float pr = u_progress;
      float rate = pr < 0.5 ? 1.0 : pr < 0.75 ? 2.0 : pr < 0.9 ? 4.0 : 8.0;
      float on = step(fract(u_beat * rate), 0.45);
      float fill = step(1.0 - uv.y, 0.15 + 0.85 * pr);
      vec3 c = mix(hsv(u_hue, 1.0, 1.0), vec3(1.0), pr * 0.8);
      return c * fill * (on > 0.5 ? 0.3 + 0.7 * pr : 0.03);
    }
    if (sc == 3) {                                                  // BREAKDOWN: sparse, synced
      float hb = 0.5 + 0.5 * cos(3.14159 * mod(u_beat, 2.0));
      float pl = 0.5 + 0.25 * sin(p.x * 5.0 + u_beat * 0.3) + 0.25 * sin((p.x + p.y * 2.0) * 3.0 - u_beat * 0.2);
      vec3 c = hsv(u_hue - 0.05 + 0.3 * pl, 0.55 + 0.35 * u_sp, (0.03 + 0.08 * u_energy + 0.05 * u_sp) * (0.5 + 0.5 * hb));
      vec2 cell = floor(uv * vec2(24.0 * u_aspect, 24.0));
      float eighth = floor(u_beat * 2.0);
      float spark = step(0.985 - 0.02 * u_sp, hash(cell + eighth)) * exp(-fract(u_beat * 2.0) * 5.0);
      return c + vec3(spark * (0.6 + 0.4 * u_sp));
    }
    if (sc == 2) {                                                  // GROOVE
      float wave = exp(-abs(r - (u_frac * 0.8)) * 10.0) * k;
      vec3 c = hsv(u_hue + 0.03 * mod(u_bar, 4.0) + r * 0.2, 1.0, 0.1 + 0.55 * k);
      c += hsv(u_hue + 0.5, 0.6, 1.0) * wave * 0.7;
      if (u_bwb < 1.5) c = mix(c, vec3(1.0), 0.3 * k);
      return c;
    }
    float breathe = 0.5 + 0.5 * sin(u_beat * 3.14159 / 4.0);       // INTRO / OUTRO / IDLE / PAUSED
    float fade = sc == 8 ? 0.6 : sc == 9 ? 0.3 : 1.0;
    return hsv(u_hue + uv.x * 0.15, 0.8, (0.05 + 0.12 * breathe) * fade * (1.0 - 0.5 * r));
  }`,
};
// Test card: grid, border, diagonals, centre circle, coloured corners (no derivative extension needed).
// The centre flashes on every beat (red on the one) for an eighth of a beat (~60 ms): line it up with the kick by ear, or film
// it next to a deck in slow motion, with the editor's latency slider.
CONTENT.test = `vec3 content(vec2 uv) {
  vec2 g = abs(fract(uv * 10.0 + 0.5) - 0.5) * 10.0;
  float grid = step(min(g.x * u_aspect, g.y), 0.02);
  float border = step(min(min(uv.x, 1.0 - uv.x) * u_aspect, min(uv.y, 1.0 - uv.y)), 0.012);
  float diag = step(abs(uv.x - uv.y), 0.004) + step(abs(uv.x - (1.0 - uv.y)), 0.004);
  vec2 cp = (uv - 0.5) * vec2(u_aspect, 1.0);
  float circle = step(abs(length(cp) - 0.4), 0.004);
  vec3 c = vec3(0.35) * grid + vec3(1.0) * clamp(border + circle + diag * 0.6, 0.0, 1.0);
  float flash = step(u_frac, 0.12) * step(length(cp), 0.4);                // the first eighth of the beat (~60 ms)
  if (flash > 0.5) c = u_bwb < 1.5 ? vec3(1.0, 0.1, 0.1) : vec3(1.0);
  float m = 0.12;
  if (uv.x < m / u_aspect && uv.y < m) c = vec3(1.0, 0.0, 0.0);
  if (uv.x > 1.0 - m / u_aspect && uv.y < m) c = vec3(0.0, 1.0, 0.0);
  if (uv.x > 1.0 - m / u_aspect && uv.y > 1.0 - m) c = vec3(0.0, 0.3, 1.0);
  if (uv.x < m / u_aspect && uv.y > 1.0 - m) c = vec3(1.0, 1.0, 0.0);
  return c;
}`;

// ---------------------------------------------------------------- renderer

class MapRenderer {
  constructor(canvas, overlay) {
    this.cv = canvas; this.ov = overlay; this.o = overlay.getContext("2d");
    const gl = canvas.getContext("webgl", { antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: false });
    if (!gl) throw new Error("WebGL not available");
    this.gl = gl;
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    this.progs = {};
    for (const [name, src] of Object.entries(CONTENT)) this.progs[name] = this._program(COMMON + src);
    this.tex = gl.createTexture();
    this.titleCanvas = document.createElement("canvas");
    this.titleCanvas.width = 1024; this.titleCanvas.height = 256;
    this.titleVer = -1;
    this.layout = null;
    this.clock = new ShowClock();
    this.genParams = {};      // live values from the visuals service
    this.genAuto = {};        // per-parameter automation settings, from the same place
    this.genSpec = {};        // id -> {min, max, step, kind} out of the sketch's schema
    this.genLive = {};        // what the shader actually gets: genParams with automation applied
    this.genFreeze = false;   // hold every automated value where it is (the page's Freeze)
    this._frz = null;
    this.lastFrame = null;    // the clock frame this draw used, for pages that want to read it
    this.genError = null;
    this.liveSketch = null;   // the active sketch's name
    this.sketches = {};       // "name|preset" -> { prog, values } once loaded, { loading } / { error } before
    this.wave = null;         // the live track's waveform (setWave)
    this.waveTex = gl.createTexture();
    this.textTex = gl.createTexture();
    this.textN = 1;
    this.textCanvas = document.createElement("canvas");
    // 2048 across eight rows is 256px a row. A near ring can magnify one row over half the
    // screen, and at 128 the diagonals of the letterforms stair-step visibly.
    this.textCanvas.width = 2048; this.textCanvas.height = 2048;
    this.setText("SEKTOR5");
  }

  // The live track's waveform from the visuals service: RGBA bytes (height, bass, mids, highs), base64.
  setWave(w) {
    const gl = this.gl, bin = atob(w.data), px = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) px[i] = bin.charCodeAt(i);
    gl.bindTexture(gl.TEXTURE_2D, this.waveTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w.w, w.h, 0, gl.RGBA, gl.UNSIGNED_BYTE, px);
    for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.NEAREST], [gl.TEXTURE_MAG_FILTER, gl.NEAREST],
                          [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]])
      gl.texParameteri(gl.TEXTURE_2D, k, v);
    this.wave = { w: w.w, h: w.h, spb: w.spb, beats: w.beats, loop: w.loop ? 1 : 0, title: w.title, source: w.source, px };   // px: for pages that draw it (VJ.waveStrip)
  }

  // The words typed on the Visuals page, drawn into an eight-row atlas: one word per row,
  // each scaled to fit its row so the letterforms stay right whatever the word's length. Split
  // on | or a newline. Done on the CPU once per change, so the shader just samples it.
  setText(str) {
    const words = String(str || "").split(/[|\n]/).map(w => w.trim()).filter(Boolean).slice(0, 8);
    if (!words.length) words.push("SEKTOR5");
    this.textN = words.length;
    const c = this.textCanvas, g = c.getContext("2d"), ROW = c.height / 8;
    g.fillStyle = "#000"; g.fillRect(0, 0, c.width, c.height);
    g.fillStyle = "#fff"; g.textAlign = "center"; g.textBaseline = "middle";
    words.forEach((w, i) => {
      let size = Math.round(ROW * 0.82);
      g.font = `900 ${size}px system-ui, sans-serif`;
      const max = c.width * 0.96;
      const wide = g.measureText(w).width;
      if (wide > max) {                                   // long words shrink to fit their row
        size = Math.max(8, Math.floor(size * max / wide));
        g.font = `900 ${size}px system-ui, sans-serif`;
      }
      g.fillText(w, c.width / 2, i * ROW + ROW / 2);
    });
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.textTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, gl.LUMINANCE, gl.UNSIGNED_BYTE, c);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.text = str;
  }

  // Compile the visuals service's sketch as content "gen". A broken sketch keeps the last good one.
  // With trans ({mode, beats, sync, seed}), surfaces showing the live sketch keep the old one up
  // until the next beat, bar or phrase (sync), then hand over through the transition (see draw).
  setSketch(sk, trans) {
    // The sketch that was live may have been changed on the Visuals page: fetch it afresh next time.
    if (this.liveSketch && this.liveSketch !== sk.name)
      for (const k of Object.keys(this.sketches)) if (k.startsWith(this.liveSketch + "|")) delete this.sketches[k];
    this.liveSketch = sk.name;
    try {
      const ids = sk.groups.flatMap(g => g.params.map(p => p.id));
      const spec = {};
      for (const g of sk.groups) for (const p of g.params)
        spec[p.id] = { min: p.min, max: p.max, step: p.step, kind: p.kind || "" };
      const prog = this._program(COMMON + sk.glsl, ids.map(id => "p_" + id));
      prog.ids = ids; prog.name = sk.name; prog.climax = sk.climax || null;
      if (trans && this.progs.gen) this._beginTrans(trans);          // before genSpec changes: the outgoing keeps its own
      this.genSpec = spec;
      this.progs.gen = prog; this.genError = null;
    } catch (e) {
      this.genError = String(e); console.error("sketch", sk.name, e);
    }
  }

  // New live values; with trans, the same sketch morphs from its old values (a preset change).
  setParams(params, trans) {
    if (trans && this.progs.gen) this._beginTrans(trans);
    this.genParams = params;
  }

  // Keep what's showing now (the incoming side of a transition already running) as the outgoing,
  // with its own automation still moving (a copy: the pages edit theirs in place), so an LFO'd
  // value doesn't snap to its held value as the transition starts.
  // A change while the last one is still waiting for its sync point keeps that one's outgoing.
  // The outgoing keeps its words too: it takes the text texture as it is, and the incoming gets a
  // fresh copy, which the new sketch's words (sent right after it) then replace. Sharing one, the
  // outgoing sketch switched to the incoming one's words for the whole handover.
  _beginTrans(t) {
    const waiting = this.trans && !(this.trans.p >= 0);
    const out = waiting ? this.trans.out : { prog: this.progs.gen, params: this.genParams, spec: this.genSpec,
                                             auto: JSON.parse(JSON.stringify(this.genAuto || {})), live: {},
                                             textTex: this.textTex, textN: this.textN };
    if (!waiting) {
      Object.assign(out.live, this.genLive);
      if (this.trans) this.gl.deleteTexture(this.trans.out.textTex);   // cut short: its outgoing is gone
      this.textTex = this.gl.createTexture();
      this.setText(this.text);
    }
    this.trans = { out, mode: t.mode ?? 0,
                   beats: Math.max(0, t.beats ?? 4), sync: t.sync || "now", seed: t.seed ?? Math.random(), t0: null };
  }

  // The beat the transition starts on: now, or the next beat / bar / phrase (4 bars). Phrases need
  // the track's timeline (bar > 0: beat 1 is its first downbeat); without one, the next bar.
  _transStart(f) {
    const b = f.beat, T = this.trans, sync = T.sync;
    // Land on the drop: the transition's cut (its end, or a flash's peak) falls on the drop's downbeat.
    // Too little time left and it's shortened to fit; no drop known and it waits for the next bar.
    if (sync === "drop") {
      if (f.drop !== null && f.todrop > 0) {
        const land = T.mode === 10 ? 0.5 : 1;
        if (f.drop - T.beats * land < b) T.beats = Math.max(0.25, (f.drop - b) / land);
        return f.drop - T.beats * land;
      }
      return Math.floor(b) - (f.bwb - 1) + 4;
    }
    if (sync === "beat") return Math.floor(b) + 1;
    if (sync === "phrase" && f.bar > 0) return Math.ceil((b - 1 + 0.001) / 16) * 16 + 1;
    if (sync === "bar" || sync === "phrase") return Math.floor(b) - (f.bwb - 1) + 4;
    return b;
  }

  // What a "gen" surface draws: the live sketch, or its own one (loaded on first use; nothing until then).
  // The live one gets genLive -- the held values with this frame's automation on top. A surface
  // pinned to its own sketch gets the plain values it was fetched with: automation belongs to the
  // sketch the Visuals page is driving, and there is only one set of it.
  sketchFor(s) {
    if (!s.sketch || s.sketch === this.liveSketch) return this.progs.gen ? { prog: this.progs.gen, values: this.genLive } : null;
    const key = s.sketch + "|" + (s.preset || ""), e = this.sketches[key];
    if (!e) this._loadSketch(s.sketch, s.preset, key);
    return e && e.prog ? e : null;
  }

  async _loadSketch(name, preset, key) {
    this.sketches[key] = { loading: true };
    const base = visualsBase();
    try {
      const r = await fetch(`${base}/api/sketches/${encodeURIComponent(name)}` + (preset ? `?preset=${encodeURIComponent(preset)}` : ""));
      if (!r.ok) throw new Error(`${name}: ${r.status}`);
      const { sketch: sk, values } = await r.json();
      const ids = sk.groups.flatMap(g => g.params.map(p => p.id));
      const prog = this._program(COMMON + sk.glsl, ids.map(id => "p_" + id));
      prog.ids = ids; prog.name = sk.name; prog.climax = sk.climax || null;
      this.sketches[key] = { prog, values };
    } catch (e) {
      console.error("sketch", name, e);
      this.sketches[key] = { error: String(e) };
      setTimeout(() => { if (this.sketches[key] && this.sketches[key].error) delete this.sketches[key]; }, 15000);   // retry later
    }
  }

  _program(fsrc, extra = []) {
    const gl = this.gl;
    const sh = (type, src) => {
      const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    };
    const p = gl.createProgram();
    gl.attachShader(p, sh(gl.VERTEX_SHADER, VERT)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fsrc));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    const u = {};
    for (const n of ["u_res", "u_Hinv", "u_aspect", "u_beat", "u_frac", "u_bwb", "u_bar", "u_hue", "u_scene", "u_progress",
                     "u_since", "u_energy", "u_sp", "u_opacity", "u_bright", "u_sel", "u_time", "u_tex",
                     "u_radius", "u_border", "u_bbright", "u_bsat", "u_bpulse", "u_px", "u_box", "u_tri", "u_dia",
                     "u_wave", "u_wv", "u_wloop", "u_text", "u_textn", "u_trole", "u_tp", "u_tmode", "u_tseed", "u_tdur", "u_todrop", "u_cbeat", ...extra])
      u[n] = gl.getUniformLocation(p, n);
    return { p, u, a: gl.getAttribLocation(p, "a") };
  }

  _updateTitle() {
    if (this.clock.titleVer === this.titleVer) return;
    this.titleVer = this.clock.titleVer;
    const c = this.titleCanvas, g = c.getContext("2d");
    g.fillStyle = "#000"; g.fillRect(0, 0, c.width, c.height);
    g.fillStyle = "#fff"; g.textAlign = "center"; g.textBaseline = "middle";
    let size = 120, text = this.clock.title || "SEKTOR5";
    g.font = `900 ${size}px system-ui, sans-serif`;
    while (g.measureText(text).width > c.width * 0.92 && size > 30) { size -= 6; g.font = `900 ${size}px system-ui, sans-serif`; }
    g.fillText(text, c.width / 2, c.height / 2);
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, gl.LUMINANCE, gl.UNSIGNED_BYTE, c);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  }

  resize(w, h) {
    if (this.cv.width === w && this.cv.height === h) return;
    for (const c of [this.cv, this.ov]) { c.width = w; c.height = h; }
  }

  // GPU name, for the projector's stats.
  gpuName() {
    const gl = this.gl, ext = gl.getExtension("WEBGL_debug_renderer_info");
    return String(ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)).slice(0, 80);
  }

  draw(now, opts = {}) {
    const gl = this.gl, L = this.layout;
    const W = this.cv.width, H = this.cv.height;
    gl.viewport(0, 0, W, H);
    gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
    if (this.ovDirty) { this.o.clearRect(0, 0, W, H); this.ovDirty = false; }   // skip when nothing was drawn
    if (!L) return;
    this.clock.lead = L.lead_ms ?? 60;
    const f = this.clock.frame(now);
    this.lastFrame = f;
    this._genFrame(f, now);
    this._updateTitle();
    gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    const P = this.projectorId(opts.projector), mine = x => (x.projector || "main") === P;
    // A transition of the live sketch, if one is pending or running: before its start the old one stays up.
    const T = this.trans;
    let tp = null;
    if (T) {
      if (T.t0 !== null && f.beat < T.last - 1)                 // the beat clock jumped back (new master, seek,
        T.t0 = T.p >= 0 ? f.beat - T.p * T.beats : null;        // idle -> live): carry on from where it had got to
      if (T.t0 === null) T.t0 = this._transStart(f);
      tp = T.beats > 0 ? (f.beat - T.t0) / T.beats : (f.beat >= T.t0 ? 1 : -1);
      T.last = f.beat; T.p = tp;
      if (tp >= 1) { gl.deleteTexture(T.out.textTex); this.trans = null; tp = null; }
    }
    for (const s of L.surfaces) {
      if (!mine(s)) continue;
      const test = L.test || opts.test;
      let pr = this.progs[test ? "test" : s.content] || this.progs.show, vals = this.genParams;
      if (!test && s.content === "gen") {
        const g = this.sketchFor(s);
        if (!g) continue;                                       // its sketch is still loading
        pr = g.prog; vals = g.values;
      }
      if (tp !== null && pr === this.progs.gen && !s.sketch) {   // pinned surfaces don't transition
        if (tp < 0) this._surface(T.out.prog, s, f, now, W, H, T.out.live, 0);
        else {
          this._surface(T.out.prog, s, f, now, W, H, T.out.live, 2, tp, T);
          this._surface(pr, s, f, now, W, H, vals, 1, tp, T);
        }
      } else this._surface(pr, s, f, now, W, H, vals, 0);
    }
    // Masks (black) on the overlay, then edit handles.
    const o = this.o;
    o.fillStyle = "#000";
    if (L.masks.length || L.edit || opts.handles) this.ovDirty = true;
    for (const m of L.masks) {
      if (!mine(m)) continue;
      o.beginPath();
      m.points.forEach(([x, y], i) => (i ? o.lineTo(x * W, y * H) : o.moveTo(x * W, y * H)));
      o.closePath(); o.fill();
    }
    if (L.edit || opts.handles) this.drawHandles(opts);
  }

  // The beat a sketch's climax cycle runs on. A sketch's JSON can declare "climax": {"cycle": the param
  // holding its cycle in beats, "peak": where in the cycle its best moment is (0..1, a number or an
  // expression of its params), "lock": the param that turns this on, "what": a description}. When
  // showbrain predicts a drop, the cycle is eased (running faster, up to twice as fast, or slower, down
  // to held) so its peak lands on the drop's downbeat, arriving about a bar early; with no drop known
  // it runs on from wherever it is, so it never jumps.
  _cbeat(pr, params, f) {
    const c = pr.climax;
    if (!c) return f.beat;
    this._clx = this._clx || new WeakMap();                          // per program: dropped with it
    const st = this._clx.get(pr) || { off: 0, last: f.beat };
    const dt = Math.max(0, Math.min(4, f.beat - st.last));
    st.last = f.beat;
    const C = +params[c.cycle] || 0, on = c.lock ? (params[c.lock] ?? 1) > 0.5 : true;
    if (C > 0 && on && f.drop !== null && f.todrop >= 0) {
      const peak = this._peak(c.peak, params);
      const target = Math.round(((peak * C - f.drop) % C + C) % C);   // whole beats, so steps stay on the beat
      let d = ((target - st.off) % C + C) % C;
      if (d > C / 2) d -= C;                                           // the shorter way round
      // Pace it to arrive about a bar early: at least a quarter faster or slower, at most twice as fast (or held).
      const rate = Math.min(1, Math.max(0.25, Math.abs(d) / Math.max(f.todrop - 4, 1)));
      const step = rate * dt;
      st.off = Math.abs(d) <= step ? target : st.off + Math.sign(d) * step;
      st.off = ((st.off % C) + C) % C;
    }
    this._clx.set(pr, st);
    return f.beat + st.off;
  }

  // A climax "peak": a number, or a small expression of the sketch's params ("floor(cycle*(1-slip))/cycle").
  // Compiled once per expression (this runs every frame), reading the params as its argument.
  _peak(expr, params) {
    if (typeof expr === "number") return expr;
    if (typeof expr !== "string" || !/^[\w\s.+\-*\/()?:<>=]+$/.test(expr)) return 0;
    this._peaks = this._peaks || new Map();
    let fn = this._peaks.get(expr);
    if (fn === undefined) {
      const js = expr.replace(/[A-Za-z_]\w*/g, id => id === "floor" ? "Math.floor" : `(+P[${JSON.stringify(id)}] || 0)`);
      try { fn = Function("P", `"use strict"; return (${js});`); } catch (e) { fn = null; }
      this._peaks.set(expr, fn);
    }
    if (!fn) return 0;
    try { const v = fn(params); return Number.isFinite(v) ? ((v % 1) + 1) % 1 : 0; }
    catch (e) { return 0; }
  }

  // Draw one surface with a program. role: 0 normal, 1 incoming, 2 outgoing (tp, T: the transition).
  _surface(pr, s, f, now, W, H, params, role, tp = 0, T = null) {
    const gl = this.gl, L = this.layout;
    gl.useProgram(pr.p);
    gl.enableVertexAttribArray(pr.a);
    gl.vertexAttribPointer(pr.a, 2, gl.FLOAT, false, 0, 0);
    const u = pr.u;
    gl.uniform2f(u.u_res, W, H);
    gl.uniformMatrix3fv(u.u_Hinv, false, colMajor(invert3(surfaceMatrix(s.corners, s.shape))));
    gl.uniform1f(u.u_tri, s.corners.length === 3 ? 1 : 0);
    gl.uniform1f(u.u_dia, isDiamond(s) ? 1 : 0);
    const xs = s.corners.map(c => c[0]), ys = s.corners.map(c => c[1]);
    gl.uniform4f(u.u_box, 2 * Math.min(...xs) - 1, 1 - 2 * Math.max(...ys), 2 * Math.max(...xs) - 1, 1 - 2 * Math.min(...ys));
    const [qw, qh] = quadSize(s.corners, W, H, isDiamond(s) ? "diamond" : null);
    gl.uniform1f(u.u_aspect, qh > 1 ? qw / qh : 1);
    gl.uniform1f(u.u_px, 1 / Math.max(qh, 1));
    gl.uniform1f(u.u_beat, f.beat); gl.uniform1f(u.u_frac, f.frac); gl.uniform1f(u.u_bwb, f.bwb);
    gl.uniform1f(u.u_bar, f.bar); gl.uniform1f(u.u_hue, (f.hue + (s.hue_shift || 0) + 1) % 1);
    gl.uniform1f(u.u_scene, f.scene); gl.uniform1f(u.u_progress, f.progress); gl.uniform1f(u.u_since, f.since);
    gl.uniform1f(u.u_energy, f.energy); gl.uniform1f(u.u_sp, f.sp);
    gl.uniform1f(u.u_opacity, s.opacity ?? 1); gl.uniform1f(u.u_bright, L.brightness ?? 1);
    gl.uniform1f(u.u_sel, L.edit && L.selected === s.id ? 1 : 0);
    gl.uniform1f(u.u_time, now / 1000);
    gl.uniform1f(u.u_radius, s.radius || 0); gl.uniform1f(u.u_border, s.border || 0);
    gl.uniform1f(u.u_bbright, s.border_bright ?? 1); gl.uniform1f(u.u_bsat, s.border_sat ?? 0);
    gl.uniform1f(u.u_bpulse, s.border_pulse ?? 0);
    gl.uniform1f(u.u_trole, role); gl.uniform1f(u.u_tp, Math.min(Math.max(tp, 0), 1));
    gl.uniform1f(u.u_tmode, T ? T.mode : 0); gl.uniform1f(u.u_tseed, T ? T.seed * 97 : 0);
    gl.uniform1f(u.u_tdur, T ? T.beats : 0);
    gl.uniform1f(u.u_todrop, f.todrop ?? -1); gl.uniform1f(u.u_cbeat, this._cbeat(pr, params, f));
    if (pr.ids) for (const id of pr.ids) gl.uniform1f(u["p_" + id], params[id] ?? 0);
    const wv = this.wave;
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, wv ? this.waveTex : this.tex); gl.uniform1i(u.u_wave, 1);
    gl.uniform4f(u.u_wv, wv ? wv.w : 1, wv ? wv.h : 1, wv ? wv.spb : 0, wv ? wv.beats : 0);
    gl.uniform1f(u.u_wloop, wv ? wv.loop : 0);
    const own = role === 2 && T && T.out.textTex;                  // the outgoing side keeps its own words
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, own ? T.out.textTex : this.textTex); gl.uniform1i(u.u_text, 2);
    gl.uniform1f(u.u_textn, own ? T.out.textN : this.textN);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, this.tex); gl.uniform1i(u.u_tex, 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  // Which projector this page draws: the one asked for, if the layout has it, else the first.
  projectorId(want) {
    const ids = ((this.layout && this.layout.projectors) || [{ id: "main" }]).map(p => p.id);
    return ids.includes(want) ? want : ids[0];
  }

  // The live parameter values for this frame: the held values, with automation moved on top.
  // Once per frame and shared by every surface, so a layout with six of them costs the same.
  _genFrame(f, now) {
    this._automate(this.genLive, this.genParams, this.genAuto, this.genSpec, f, now);
    const T = this.trans;
    if (T) this._automate(T.out.live, T.out.params, T.out.auto, T.out.spec, f, now);
  }

  _automate(live, params, A, S, f, now) {
    for (const id in params) live[id] = params[id];
    // The beat counter shifted so downbeats are multiples of 4, same as barBeat() in the
    // shaders, so "retrigger on bar" fires on the 1 and not wherever the track happened to start.
    const bb = f.beat - ((((Math.floor(f.beat) - (f.bwb - 1)) % 4) + 4) % 4);
    const inBar = bb - 4 * Math.floor(bb / 4);
    const t = now / 1000;
    // Freeze holds the clock the automation reads rather than switching it off, so every value
    // stays exactly where it was. Letting go goes back to the live beat, which can be a jump:
    // that keeps every page's answer a function of the beat alone (docs/visuals-live.md).
    if (this.genFreeze) { if (!this._frz) this._frz = { beat: f.beat, inBar, t }; }
    else this._frz = null;
    const F = this._frz;
    for (const id in A) {
      const a = A[id];
      if (!a || !a.on) continue;
      const s = S[id];
      let v = autoEval(a, F ? F.beat : f.beat, F ? F.inBar : inBar, F ? F.t : t);
      if (s) v = Math.max(s.min, Math.min(s.max, v));    // never outside what the sketch allows
      live[id] = v;
    }
  }

  drawHandles(opts = {}) {
    const L = this.layout, o = this.o, W = this.ov.width, H = this.ov.height;
    const P = this.projectorId(opts.projector), mine = x => (x.projector || "main") === P;
    const r = Math.max(8, Math.min(W, H) * 0.012);
    o.lineWidth = Math.max(2, r / 4);
    o.font = `600 ${Math.round(r * 1.6)}px system-ui, sans-serif`;
    for (const s of L.surfaces) {
      if (!mine(s)) continue;
      const sel = s.id === L.selected;
      o.strokeStyle = sel ? "#2fe6ff" : "rgba(255,255,255,0.6)";
      o.beginPath();
      s.corners.forEach(([x, y], i) => (i ? o.lineTo(x * W, y * H) : o.moveTo(x * W, y * H)));
      o.closePath(); o.stroke();
      s.corners.forEach(([x, y], i) => {
        o.fillStyle = ["#f33", "#3f3", "#39f", "#ff3"][i];
        o.beginPath(); o.arc(x * W, y * H, sel ? r * 1.3 : r, 0, Math.PI * 2); o.fill();
        if (sel) { o.strokeStyle = "#fff"; o.stroke(); }
      });
      const k = s.corners.length, cx = s.corners.reduce((a, c) => a + c[0], 0) / k * W, cy = s.corners.reduce((a, c) => a + c[1], 0) / k * H;
      o.fillStyle = sel ? "#2fe6ff" : "#fff"; o.textAlign = "center";
      o.fillText(`${s.name || s.id} · ${s.content === "gen" && s.sketch ? s.sketch + (s.preset ? " · " + s.preset : "") : s.content}`, cx, cy);
    }
    for (const m of L.masks) {
      if (!mine(m)) continue;
      o.strokeStyle = m.id === L.selected ? "#ff2fd0" : "rgba(255,47,208,0.6)";
      o.setLineDash([r, r / 2]);
      o.beginPath();
      m.points.forEach(([x, y], i) => (i ? o.lineTo(x * W, y * H) : o.moveTo(x * W, y * H)));
      o.closePath(); o.stroke(); o.setLineDash([]);
      if (m.id === L.selected) m.points.forEach(([x, y]) => {
        o.fillStyle = "#ff2fd0"; o.beginPath(); o.arc(x * W, y * H, r * 0.8, 0, Math.PI * 2); o.fill();
      });
    }
    if (opts.draft && opts.draft.length) {
      o.strokeStyle = "#ff2fd0"; o.beginPath();
      opts.draft.forEach(([x, y], i) => (i ? o.lineTo(x * W, y * H) : o.moveTo(x * W, y * H)));
      o.stroke();
      opts.draft.forEach(([x, y]) => { o.fillStyle = "#ff2fd0"; o.beginPath(); o.arc(x * W, y * H, r * 0.7, 0, Math.PI * 2); o.fill(); });
    }
  }
}

// Connect to an event stream (the projector host's by default); calls the handlers as messages arrive.
// Each service says hello with a version of its page code; when that changes (a deploy),
// the page reloads itself so nobody has to hard-refresh the projector. reload: false opts out.
// Keeps a preview smooth on a slow phone or tablet. Once a second it looks at the frame rate: under
// ~45 fps it draws a little smaller (down to half the resolution, the browser scales it up), over
// ~57 it climbs back. A device that keeps up never changes. If going smaller didn't help (a phone in
// Low Power Mode is held at 30 fps whatever it draws), it goes back to full and stops trying.
// apply() is the page's resize; it multiplies its pixel size by .scale. Call frame(now) every frame.
class AutoRes {
  constructor(apply) { this.apply = apply; this.scale = 1; this.n = 0; this.t0 = 0; this.hold = 0; this.prev = null; this.stuck = false; }
  frame(now) {
    if (document.hidden) { this.t0 = 0; return; }
    if (!this.t0) { this.t0 = now; this.n = 0; if (!this.hold) this.hold = now + 3000; return; }   // settle after loading
    this.n++;
    const dt = now - this.t0;
    if (dt < 1000) return;
    const fps = this.n * 1000 / dt;
    this.t0 = now; this.n = 0;
    if (now < this.hold) return;
    let s = this.scale;
    if (this.prev && fps <= this.prev.fps + 2) { s = this.prev.scale; this.stuck = true; }      // smaller didn't help
    else if (fps < 45 && s > 0.5 && !this.stuck) s = Math.max(0.5, Math.round(s * 0.85 * 100) / 100);
    else if (fps > 57 && s < 1) { s = Math.min(1, Math.round(s * 1.1 * 100) / 100); this.stuck = false; }
    this.prev = s < this.scale ? { fps, scale: this.scale } : null;
    if (s !== this.scale) { this.scale = s; this.hold = now + 2000; this.apply(); }
  }
}

// pauseHidden: close the stream while the page is hidden (a phone's screen off, another tab) and open it
// again when it's back: the server starts every connection with everything (sketch, values, ...), so
// nothing is missed, and nothing piles up in the meantime. Off for the projector's own output.
function connectEvents(renderer, { onLayout, onScreen, onScreens, onStatus, onSketch, onParams, onAuto, onText, onTransition, onShuffle, onBackdrop, url = "/api/events", state = true, reload = true, pauseHidden = false } = {}) {
  let es, version = null, glsl = null;
  const open = () => {
    es = new EventSource(url);
    es.onopen = () => onStatus && onStatus(true);
    es.onerror = () => onStatus && onStatus(false);
    es.onmessage = e => {
      const m = JSON.parse(e.data);
      if (m.t === "state") { if (state) renderer.clock.update(m.s); }
      else if (m.t === "hello") {
        if (version && m.version !== version && reload) setTimeout(() => location.reload(), 300 + Math.random() * 700);
        version = m.version;
      }
      else if (m.t === "layout") onLayout ? onLayout(m.layout) : (renderer.layout = m.layout);
      else if (m.t === "screen" && onScreen) onScreen(m.screen);
      else if (m.t === "screens" && onScreens) onScreens(m.screens);
      else if (m.t === "sketch") {
        // The same sketch again (a reconnect): no need to rebuild its shader, which would hitch the picture.
        const key = m.sketch ? m.sketch.name + "\n" + m.sketch.glsl + "\n" + JSON.stringify([m.sketch.groups, m.sketch.climax || null]) : null;
        const same = !m.trans && key && key === glsl && m.sketch.name === renderer.liveSketch && renderer.progs.gen;
        if (!same) renderer.setSketch(m.sketch, m.trans);
        glsl = key;                      // name, shader, settings and climax: anything else is a different sketch
        onSketch && onSketch(m.sketch);
      }
      else if (m.t === "params") { renderer.setParams(m.params, m.trans); onParams && onParams(m.params); }
      else if (m.t === "transition" && onTransition) onTransition(m.settings);
      else if (m.t === "backdrop" && onBackdrop) onBackdrop(m);
      else if (m.t === "auto") {
        renderer.genAuto = m.auto || {};
        renderer.genFreeze = !!m.freeze;
        onAuto && onAuto(renderer.genAuto, renderer.genFreeze);
      }
      else if (m.t === "wave") renderer.setWave(m.wave);
      else if (m.t === "text") { renderer.setText(m.text); onText && onText(m.text); }
      else if (m.t === "shuffle") onShuffle && onShuffle(m.shuffle);
    };
  };
  open();
  if (pauseHidden) document.addEventListener("visibilitychange", () => {
    if (document.hidden) { if (es) { es.close(); es = null; } }
    else if (!es) open();
  });
  return () => es && es.close();
}

// The visuals service's address: :8110 on the rig's network, /visuals through the dashboard's address
// (HTTPS / Tailscale). /s5auth.js knows; the projector output page doesn't load it, so work it out.
function visualsBase() {
  if (window.S5AUTH && S5AUTH.url) return S5AUTH.url(8110, "");
  if (location.protocol === "https:" || location.pathname.startsWith("/projection")) return location.origin + "/visuals";
  return `${location.protocol}//${location.hostname}:8110`;
}

// The visuals service (:8110, same host) feeds content "gen": its sketch and live params.
// The beat clock comes from the projector's own stream, so this one's state is ignored.
function connectVisuals(renderer, opts = {}) {   // opts as connectEvents (e.g. pauseHidden)
  // The visuals page's address comes from /s5auth.js (a port on the rig's network, /visuals over HTTPS).
  const url = visualsBase() + "/api/events";
  return connectEvents(renderer, { state: false, reload: false, ...opts, url });
}
