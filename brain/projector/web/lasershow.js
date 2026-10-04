// Sektor5 laser shows for the Stage view: big-show laser looks, locked to the show's beat clock.
//
// laserFrame(lookId, f, ctx) says what one laser fixture draws this frame:
//   { cue, level, beams: [{ yaw, pitch, rgb }], sheet: null | { dirs: [[yaw, pitch], ...], rgbA, rgbB, amount } }
// Angles are radians in the fixture's own frame (0,0 = straight at its aim point). yaw > 0 is towards
// stage centre, so every look is mirrored left/right; pitch > 0 is up. A sheet is a continuous plane
// (or, when its first and last directions meet, a cone) of scanned light, like a liquid sky or tunnel.
//
// f is the Stage page's show frame (scene, beat, frac, progress, since, hue, intensity).
// ctx: { side: -1 left | 1 right, idx, count (lasers in the rig), t (seconds), seed (per track),
//        classic: { n, spread, rgb } for the "classic" look }.
//
// Each look picks a cue per section (intro, groove, build, drop, breakdown) and changes cue every
// 8 bars (every 4 in a drop), so the show moves on with the phrasing of the track.

const TAU = Math.PI * 2, PI = Math.PI;
const lerp = (a, b, k) => a + (b - a) * k;
const hash = n => { const x = Math.sin(n * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); };
function hsl(h, s = 1, l = 0.5) {
  h = ((h % 1) + 1) % 1;
  const k = n => (n + h * 12) % 12, a = s * Math.min(l, 1 - l);
  const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
  return [f(0), f(8), f(4)];
}
export function strHash(s) { let h = 7; for (const c of String(s || "")) h = (h * 31 + c.charCodeAt(0)) | 0; return Math.abs(h); }

// ------------------------------------------------------------------ colours
const WHITE = [1, 1, 1], ICE = [0.75, 0.9, 1], RED = [1, 0.04, 0.02], GREEN = [0.08, 1, 0.18], CYAN = [0, 0.85, 1],
      VIOLET = [0.45, 0.12, 1], AMBER = [1, 0.55, 0.05];
const PAL = {
  epic:      (x, i, f)    => i % 2 ? hsl(f.hue) : ICE,                    // cool white with the track's colour
  mafia:     (x, i)       => i % 3 === 1 ? WHITE : RED,                   // red and white, nothing else
  trance:    (x, i)       => i % 4 === 3 ? CYAN : GREEN,                  // the classic green, a little cyan
  afterlife: (x, i)       => i % 3 === 2 ? VIOLET : ICE,                  // cold white and violet
  mainstage: (x, i, f, t) => hsl(x * 0.75 + t * 0.07),                    // full rainbow across the fan, drifting
  techno:    (x, i)       => i % 5 === 4 ? AMBER : WHITE,                 // white with amber flashes
};

// ------------------------------------------------------------------ cues
// Each cue: (f, c, o) -> { beams, sheet }. o: { pal, tight (1 = full size, less = narrower),
// spin (rotation speed factor), ...the look's own parameters }.
const beamsOf = (n, o, f, c, fn) => {
  const out = [];
  for (let i = 0; i < n; i++) { const x = n === 1 ? 0.5 : i / (n - 1), [yaw, pitch] = fn(x, i); out.push({ yaw, pitch, rgb: o.pal(x, i, f, c.t) }); }
  return out;
};
const sheetOf = (n, o, f, c, fn, amount, closed = false) => {
  const dirs = [];
  for (let i = 0; i < n; i++) dirs.push(fn(closed ? i / n : i / (n - 1)));
  if (closed) dirs.push(dirs[0]);
  return { dirs, rgbA: o.pal(0, 0, f, c.t), rgbB: o.pal(1, 1, f, c.t), amount };
};

const CUES = {
  // A wide fan swinging across the crowd, a half-swing per beat.
  fan: (f, c, o) => ({ beams: beamsOf(o.n || 24, o, f, c, x => [
    (x - 0.5) * 1.7 * o.tight + Math.sin(f.beat * PI / 2) * 0.45, -0.02 + 0.03 * Math.sin(f.beat * PI + x * 6)]) }),

  // The rippling horizon: a dense fan whose beams rise and fall in a wave that travels across it.
  wave: (f, c, o) => ({ beams: beamsOf(o.n || 48, o, f, c, x => [
    (x - 0.5) * 2.0 * o.tight, -0.03 + 0.13 * (o.amp || 1) * Math.sin(TAU * x * 1.5 - f.beat * PI / 2 * o.spin)]) }),

  // A cone of beams round the aim line, turning; its surface drawn as a faint scanned sheet.
  tunnel: (f, c, o) => {
    const n = o.n || 32, kick = Math.exp(-5 * f.frac), R = (o.R || 0.22) * o.tight * (0.88 + 0.12 * kick);
    const rot = f.beat * PI / (o.slow ? 16 : 4) * o.spin * c.side;
    const dir = x => [0.12 + R * Math.cos(TAU * x + rot), R * 0.8 * Math.sin(TAU * x + rot)];
    return { beams: beamsOf(n, o, f, c, (x, i) => dir(i / n)), sheet: sheetOf(64, o, f, c, dir, 0.35, true) };
  },

  // Liquid sky: a single sheet of light over the crowd's heads, rippling slowly like water.
  sky: (f, c, o) => {
    const dir = x => [(x - 0.5) * 2.2, -0.04 + 0.035 * Math.sin(TAU * x * 2 + c.t * 1.3 * o.spin) + 0.02 * Math.sin(TAU * x * 5 - c.t * 2.1)];
    return { beams: beamsOf(2, o, f, c, x => dir(x)), sheet: sheetOf(80, o, f, c, dir, 1) };
  },

  // Crossfire: beams from each side shooting across the centre, flipping high/low on every beat.
  cross: (f, c, o) => ({ beams: beamsOf(o.n || 12, o, f, c, (x, i) => [
    0.2 + x * 0.95 + 0.15 * Math.sin(f.beat * PI / 4), ((i + Math.floor(f.beat)) % 2 ? 0.05 : -0.1)]) }),

  // Knives: a vertical fan slicing sideways across the room.
  knives: (f, c, o) => ({ beams: beamsOf(o.n || 14, o, f, c, x => [
    Math.sin(f.beat * PI / 2 * o.spin + c.idx) * 0.75, lerp(-0.3, 0.35, x) * o.tight]) }),

  // Chase: a few beams jumping to new random spots on every step (quarter or eighth notes).
  chase: (f, c, o) => {
    const div = o.div || 2, step = Math.floor(f.beat * div);
    return { beams: beamsOf(o.n || 6, o, f, c, (x, i) => {
      const r = k => hash(step * 31 + i * 7 + c.idx * 101 + c.seed % 997 + k);
      return [lerp(-0.9, 0.9, r(0)), lerp(-0.25, 0.2, r(1))];
    }) };
  },

  // Audience scan: a fan tilting from the floor up over the crowd and back, over two bars.
  scan: (f, c, o) => {
    const p = -0.28 + 0.36 * (0.5 - 0.5 * Math.cos(f.beat * PI / 4 * o.spin));
    return { beams: beamsOf(o.n || 36, o, f, c, x => [(x - 0.5) * 1.9 * o.tight, p]) };
  },

  // Sunburst: spokes bursting out from the centre once a bar, turning.
  burst: (f, c, o) => {
    const ph = (((f.beat % 4) + 4) % 4) / 4, R = 0.04 + 0.75 * Math.pow(ph, 0.6), rot = f.beat * PI / 8 * c.side;
    return { beams: beamsOf(o.n || 16, o, f, c, (x, i) => { const a = TAU * i / (o.n || 16) + rot; return [0.1 + R * Math.cos(a), R * 0.6 * Math.sin(a)]; }),
             fade: 1 - 0.6 * ph };
  },

  // Zigzag lattice: alternate beams tilting up and down, crossing into a diamond mesh.
  zigzag: (f, c, o) => ({ beams: beamsOf(o.n || 28, o, f, c, (x, i) => [
    (x - 0.5) * 1.8 * o.tight, -0.02 + (i % 2 ? 1 : -1) * 0.15 * Math.sin(f.beat * PI / 2 * o.spin)]) }),

  // Converge (builds): a wide fan closing to a single point in the middle as the build rises.
  converge: (f, c, o) => {
    const k = Math.pow(f.progress || 0, 0.8);
    return { beams: beamsOf(o.n || 32, o, f, c, x => [
      lerp((x - 0.5) * 2.0, 0.3, k) + 0.03 * Math.sin(f.beat * PI), lerp(0.12 * Math.sin(TAU * x * 2 + f.beat * PI / 2), 0, k)]) };
  },

  // ---- cues from laser-show history (styles, not anyone's show data) ----

  // Lissajous figure (Laserium, Griffith Observatory 1973): a closed curve of scanned light whose
  // frequency ratio (a:b) sets its knot; a few beams ride round it.
  lissajous: (f, c, o) => {
    const a = o.a || 3, b = o.b || 2, ph = c.t * 0.35 * o.spin + f.beat * PI / 16, A = 0.42 * o.tight, B = 0.26 * o.tight;
    const dir = x => [0.12 + A * Math.sin(a * TAU * x + ph), 0.1 + B * Math.sin(b * TAU * x)];
    return { beams: beamsOf(o.n || 8, o, f, c, x => dir((x + f.beat / 8) % 1)), sheet: sheetOf(120, o, f, c, dir, 0.8, true) };
  },

  // Spirograph rose (the Laserium abstracts): petals turning, the petal count from the program.
  rosette: (f, c, o) => {
    const k = o.k || 5, rot = f.beat * PI / 16 * o.spin * c.side, R = 0.36 * o.tight * (0.9 + 0.1 * Math.exp(-5 * f.frac));
    const dir = x => { const th = TAU * x, r = R * Math.cos(k * th); return [0.12 + r * Math.cos(th + rot), 0.12 + 0.7 * r * Math.sin(th + rot)]; };
    return { beams: beamsOf(o.n || 10, o, f, c, (x, i) => dir(i / (o.n || 10) + 0.5 / k)), sheet: sheetOf(140, o, f, c, dir, 0.7, true) };
  },

  // Laser harp (Jean-Michel Jarre, from 1981): a fan of upright beams, plucked one at a time in a
  // little melody the program's seed writes; the others glow dim.
  harp: (f, c, o) => {
    const n = o.n || 9, rate = o.rate || 2, step = Math.floor(f.beat * rate), since = f.beat * rate - step;
    const note = s => Math.floor(hash((o.seed ?? c.seed) % 9973 + (((s % 8) + 8) % 8) * 17) * n);
    const lit = note(step), prev = note(step - 1);
    return { beams: beamsOf(n, o, f, c, x => [(x - 0.5) * 0.9 * o.tight + 0.1, 0.3 + 0.08 * Math.sin(f.beat * PI / 8)]).map((bm, i) => {
      const k = i === lit ? 1 : i === prev ? Math.max(0.15, Math.exp(-4 * since)) : 0.15;
      return { ...bm, rgb: bm.rgb.map(v => v * k) };
    }) };
  },

  // Pyramid (Pink Floyd's 1994 Division Bell tour, Daft Punk's 2006 Alive): beams drawing a
  // triangle whose apex lifts on the kick, its faces a scanned sheet.
  pyramid: (f, c, o) => {
    const kick = Math.exp(-5 * f.frac), sw = 0.12 * Math.sin(f.beat * PI / 8 * o.spin), w = 0.75 * o.tight;
    const P = [[0.12 - w + sw, -0.12], [0.12 + sw * 0.5, 0.42 + 0.06 * kick], [0.12 + w + sw, -0.12]];
    const dir = x => { const s = x * 3, i = Math.min(2, Math.floor(s)), k = s - i, a = P[i], b = P[(i + 1) % 3]; return [lerp(a[0], b[0], k), lerp(a[1], b[1], k)]; };
    return { beams: beamsOf(o.n || 15, o, f, c, x => dir(x)), sheet: sheetOf(60, o, f, c, dir, 0.5, true) };
  },

  // Searchlight (Led Zeppelin 1977, The Who 1975): one or two fat beams carving slow arcs.
  searchlight: (f, c, o) => {
    const out = [], m = o.m || 2;
    for (let j = 0; j < m; j++) {
      const a = f.beat * PI / 8 * o.spin + j * PI, yaw = 0.15 + 0.8 * Math.sin(a), pitch = 0.08 + 0.22 * Math.sin(a * 0.5 + j);
      for (let k = 0; k < 4; k++) out.push({ yaw: yaw + (k % 2 - 0.5) * 0.008, pitch: pitch + (k > 1 ? 0.006 : -0.006), rgb: o.pal(j / Math.max(1, m - 1), j, f, c.t) });
    }
    return { beams: out };
  },

  // Helix (90s rave tunnels, HOLO-era cones): two cones turning against each other.
  helix: (f, c, o) => {
    const n = o.n || 32, rot = f.beat * PI / 4 * o.spin, R = 0.24 * o.tight;
    return { beams: beamsOf(n, o, f, c, (x, i) => { const a = TAU * (Math.floor(i / 2) / (n / 2)) + (i % 2 ? rot : -rot), r = i % 2 ? R : R * 0.6;
      return [0.12 + r * Math.cos(a), 0.06 + r * 0.8 * Math.sin(a)]; }) };
  },

  // Grid (Kraftwerk's 3-D shows, scrim lattices): rays to the points of a grid that slides.
  grid: (f, c, o) => {
    const cols = o.cols || 7, rows = o.rows || 3, dx = 0.18 * Math.sin(f.beat * PI / 8 * o.spin), dy = 0.05 * Math.sin(f.beat * PI / 4);
    const out = [];
    for (let r = 0; r < rows; r++) for (let q = 0; q < cols; q++) {
      const x = q / (cols - 1);
      out.push({ yaw: (x - 0.5) * 1.6 * o.tight + dx * (r % 2 ? 1 : -1), pitch: -0.08 + r * 0.14 + dy, rgb: o.pal(x, r * cols + q, f, c.t) });
    }
    return { beams: out };
  },

  // Shutter fan (warehouse techno): a wide fan, each beam chopped on its own 16ths.
  shutter: (f, c, o) => {
    const n = o.n || 32, step = Math.floor(f.beat * 4);
    return { beams: beamsOf(n, o, f, c, x => [(x - 0.5) * 1.8 * o.tight + 0.2 * Math.sin(f.beat * PI / 4), -0.02])
      .filter((bm, i) => hash(step * 13 + i * 7 + c.seed % 101) < (o.duty || 0.5)) };
  },

  // Starfield: fixed points over the crowd, each twinkling on its own 16th.
  starfield: (f, c, o) => {
    const n = o.n || 40, step = Math.floor(f.beat * 4), out = [];
    for (let i = 0; i < n; i++) {
      if (hash(step * 3 + i * 11 + c.idx * 5) > (o.duty || 0.35)) continue;
      out.push({ yaw: lerp(-0.9, 1.0, hash(i * 7.3 + c.seed % 31)), pitch: lerp(-0.1, 0.45, hash(i * 3.1 + 9)), rgb: o.pal(i / n, i, f, c.t) });
    }
    return { beams: out };
  },

  // Crown: a ring of beams straight up, a halo over the stage, pulsing wider on the kick.
  crown: (f, c, o) => {
    const n = o.n || 24, rot = f.beat * PI / 8 * o.spin * c.side, R = 0.22 * o.tight * (0.85 + 0.15 * Math.exp(-5 * f.frac));
    return { beams: beamsOf(n, o, f, c, (x, i) => { const a = TAU * i / n + rot; return [0.12 + R * Math.cos(a), 0.62 + 0.12 * Math.sin(a)]; }) };
  },

  // Rise (builds): a fan lifting from the floor to the sky as the build climbs, closing in.
  rise: (f, c, o) => {
    const p = f.progress || 0;
    return { beams: beamsOf(o.n || 28, o, f, c, x => [(x - 0.5) * 1.8 * (1 - 0.7 * p) + 0.1 * p, lerp(-0.25, 0.6, Math.pow(p, 0.8)) + 0.03 * Math.sin(f.beat * PI + x * 6)]) };
  },

  // The original simulated fan, in the fixture's own colour, beams and spread.
  classic: (f, c, o) => {
    const { n, spread, rgb } = c.classic, sc = f.scene;
    let sweep = Math.sin(f.beat * PI / 2) * 0.6, width = 1;
    if (sc === "DROP") sweep = Math.sin(f.beat * PI) * 0.9;
    else if (sc === "BUILD" || sc === "HOLD") { width = 1 - 0.85 * (f.progress || 0); sweep = 0; }
    else if (sc === "BREAKDOWN") { width = 0.15; sweep = Math.sin(f.beat * PI / 8) * 0.3; }
    else if (sc === "INTRO" || sc === "OUTRO") width = 0.5;
    const out = [];
    for (let i = 0; i < n; i++) {
      const k = n === 1 ? 0 : i / (n - 1) - 0.5;
      out.push({ yaw: (k * width + sweep) * spread * -c.side, pitch: -Math.sin(f.beat * 0.7 + i) * 0.05 * width, rgb });
    }
    return { beams: out };
  },
};

// ------------------------------------------------------------------ looks
// Styles modelled on the big touring shows (no artist's actual show data is used).
export const LOOKS = {
  auto:      { label: "Auto · new look each track" },
  epic:      { label: "Epic · Prydz-style", pal: "epic",
               intro: [["sky"], ["tunnel", { R: 0.1, slow: 1 }]], groove: [["wave"], ["tunnel"], ["fan"], ["scan"]],
               build: [["tunnel", { R: 0.35 }], ["converge"]], breakdown: [["sky"], ["tunnel", { R: 0.08, slow: 1 }]],
               drop: [["wave", { n: 64, amp: 1.4 }], ["tunnel", { R: 0.32, n: 48 }], ["burst", { n: 24 }], ["scan", { n: 48 }]] },
  mafia:     { label: "Red & white · SHM-style", pal: "mafia", dropGate: 2,
               intro: [["knives", { n: 6 }]], groove: [["cross"], ["chase"], ["knives"], ["zigzag"]],
               build: [["converge", { n: 24 }], ["knives", { n: 20 }]], breakdown: [["sky"], ["knives", { n: 4, spin: 0.25 }]],
               drop: [["cross", { n: 18 }], ["zigzag", { n: 36 }], ["chase", { n: 10, div: 4 }], ["knives", { n: 24, spin: 2 }]] },
  trance:    { label: "Trance green · ASOT-style", pal: "trance",
               intro: [["sky"]], groove: [["tunnel"], ["wave"], ["fan"], ["zigzag"]],
               build: [["tunnel", { R: 0.3 }], ["converge"]], breakdown: [["sky"], ["tunnel", { R: 0.12, slow: 1 }]],
               drop: [["tunnel", { R: 0.3, n: 48 }], ["wave", { n: 64 }], ["burst"], ["fan", { n: 40 }]] },
  afterlife: { label: "Dark & cinematic · Afterlife-style", pal: "afterlife",
               intro: [["knives", { n: 3, spin: 0.25 }]], groove: [["knives", { n: 5, spin: 0.5 }], ["sky"], ["tunnel", { R: 0.06, n: 12, slow: 1 }], ["scan", { n: 12, spin: 0.5 }]],
               build: [["tunnel", { R: 0.2, n: 16 }]], breakdown: [["sky"], ["knives", { n: 2, spin: 0.2 }]],
               drop: [["tunnel", { R: 0.26, n: 24 }], ["sky"], ["knives", { n: 10 }], ["wave", { n: 20, amp: 0.7, spin: 0.5 }]] },
  mainstage: { label: "Mainstage rainbow · Garrix-style", pal: "mainstage",
               intro: [["fan", { n: 12 }]], groove: [["fan"], ["zigzag"], ["chase", { n: 8 }], ["scan"]],
               build: [["converge", { n: 40 }], ["burst"]], breakdown: [["sky"], ["tunnel", { R: 0.1, slow: 1 }]],
               drop: [["burst", { n: 24 }], ["zigzag", { n: 40 }], ["scan", { n: 48 }], ["fan", { n: 48 }], ["chase", { n: 12, div: 4 }]] },
  techno:    { label: "Warehouse techno · strobing white", pal: "techno", dropGate: 4,
               intro: [["knives", { n: 4 }]], groove: [["chase", { n: 4 }], ["knives", { n: 8 }], ["cross", { n: 6 }]],
               build: [["converge", { n: 16 }]], breakdown: [["sky"]],
               drop: [["chase", { n: 8, div: 4 }], ["knives", { n: 16, spin: 2 }], ["cross", { n: 12 }], ["zigzag", { n: 24 }]] },
  classic:   { label: "Classic · fixture colour" },
};
const AUTO_POOL = ["epic", "mafia", "trance", "afterlife", "mainstage", "techno"];
export function resolveLook(id, seed) { return id === "auto" || !LOOKS[id] ? AUTO_POOL[((seed % AUTO_POOL.length) + AUTO_POOL.length) % AUTO_POOL.length] : id; }

const SECTION = { INTRO: "intro", OUTRO: "intro", GROOVE: "groove", BUILD: "build", HOLD: "build", DROP: "drop", BREAKDOWN: "breakdown" };
const LEVEL = { intro: 0.45, groove: 0.75, build: 0.5, drop: 1, breakdown: 0.6 };
const fr = x => ((x % 1) + 1) % 1;

// ------------------------------------------------------------------ no yellow
// The rig never shows yellow (looks.py no_yellow, YELLOW): a beam from amber to chartreuse
// (34-90 degrees) turns orange or green, whichever is nearer, keeping its brightness.
export function noYellow(rgb) {
  const [r, g, b] = rgb, mx = Math.max(r, g, b), mn = Math.min(r, g, b), c = mx - mn;
  if (b !== mn || c <= 0.1 * mx || mx <= 0.02) return rgb;
  const h = (r >= g ? (g - b) / c : 2 - (r - b) / c) / 6;
  if (h <= 0.095 || h >= 0.25) return rgb;
  const k = (h < 0.1725 ? 0.095 : 0.25) * 6, s = c / mx;
  return k < 1 ? [mx, mx * (1 - s * (1 - k)), mx * (1 - s)] : [mx * (1 - s * (k - 1)), mx, mx * (1 - s)];
}

// ------------------------------------------------------------------ the director
// Instead of a fixed list of cues per section, every drop, build and 8-bar phrase gets its own
// program, composed when it starts: which cues (one, or a main cue with a lighter layer under it),
// how they're chopped (gate), which beams are lit (mask), the colour, how the two sides move
// (mirrored, in parallel, or one answering the other 2 beats later), the speed, and a fill into the
// next phrase. Drops get bigger through the track (the last one is a finale), and the director
// remembers its recent programs so it doesn't repeat itself. Each time a track starts it draws a new
// random salt, so the same track never gets the same show twice. Both lasers share each program
// (it's cached by section), so they stay locked together.

function rng(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length) % list.length];
function pickW(r, items) {                     // [[value, weight], ...]
  const tot = items.reduce((s, [, w]) => s + w, 0); let x = r() * tot;
  for (const [v, w] of items) if ((x -= w) <= 0) return v;
  return items[items.length - 1][0];
}

const POOL = {
  intro:     ["sky", "knives", "searchlight", "harp", "lissajous", "rosette", "crown", "fan", "tunnel"],
  groove:    ["fan", "wave", "tunnel", "scan", "cross", "knives", "chase", "zigzag", "helix", "grid", "harp", "searchlight", "shutter", "pyramid", "lissajous"],
  breakdown: ["sky", "lissajous", "rosette", "harp", "searchlight", "crown", "tunnel", "helix", "pyramid"],
  drop:      ["wave", "tunnel", "burst", "scan", "fan", "zigzag", "chase", "cross", "knives", "helix", "grid", "shutter", "starfield", "crown", "pyramid", "rosette"],
  layer:     ["sky", "lissajous", "rosette", "starfield", "searchlight", "crown", "harp"],   // light enough to sit under a main cue
};
// Per-cue parameters, drawn fresh for each program (beam counts scale with the track's energy later).
const PARAMS = {
  fan:        r => ({ n: pick(r, [16, 24, 32, 48, 56]) }),
  wave:       r => ({ n: pick(r, [32, 48, 64]), amp: 0.7 + r() * 0.8, spin: pick(r, [0.5, 1, 1, 2]) }),
  tunnel:     r => ({ R: 0.12 + r() * 0.24, n: pick(r, [16, 24, 32, 48]), slow: r() < 0.3 ? 1 : 0 }),
  scan:       r => ({ n: pick(r, [24, 36, 48]), spin: pick(r, [0.5, 1, 2]) }),
  cross:      r => ({ n: pick(r, [8, 12, 18]) }),
  knives:     r => ({ n: pick(r, [4, 8, 14, 24]), spin: pick(r, [0.5, 1, 2]) }),
  chase:      r => ({ n: pick(r, [4, 6, 10, 14]), div: pick(r, [1, 2, 4]) }),
  zigzag:     r => ({ n: pick(r, [20, 28, 40]), spin: pick(r, [0.5, 1, 2]) }),
  burst:      r => ({ n: pick(r, [12, 16, 24, 32]) }),
  helix:      r => ({ n: pick(r, [24, 32, 48]), spin: pick(r, [0.5, 1, 1.5]) }),
  grid:       r => ({ rows: pick(r, [2, 3, 4]), cols: pick(r, [5, 7, 9]), spin: pick(r, [0.5, 1]) }),
  harp:       r => ({ n: pick(r, [7, 9, 11, 13]), rate: pick(r, [1, 2, 2, 4]) }),
  searchlight: r => ({ m: pick(r, [1, 2, 3]), spin: pick(r, [0.5, 1]) }),
  shutter:    r => ({ n: pick(r, [24, 32, 48]), duty: 0.3 + r() * 0.4 }),
  starfield:  r => ({ n: pick(r, [24, 40, 60]), duty: 0.2 + r() * 0.3 }),
  crown:      r => ({ n: pick(r, [16, 24, 32]), spin: pick(r, [0.5, 1, 2]) }),
  pyramid:    r => ({ n: pick(r, [9, 15, 21]), spin: pick(r, [0.5, 1]) }),
  lissajous:  r => { const [a, b] = pick(r, [[1, 2], [2, 3], [3, 2], [3, 4], [4, 3], [5, 4], [1, 3], [5, 6]]); return { a, b, n: pick(r, [4, 8, 12]), spin: pick(r, [0.5, 1, 2]) }; },
  rosette:    r => ({ k: pick(r, [3, 4, 5, 6, 7]), n: pick(r, [6, 10, 14]), spin: pick(r, [0.5, 1, 2]) }),
  sky:        () => ({}),
  converge:   r => ({ n: pick(r, [24, 32, 40]) }),
  rise:       r => ({ n: pick(r, [20, 28, 36]) }),
};
// Cues symmetric about the aim line: these can run in parallel (both sides the same way).
const SYM = new Set(["fan", "wave", "scan", "knives", "zigzag", "grid", "shutter", "harp", "searchlight", "chase", "rise", "starfield"]);

const GATES = {
  none: () => 1,
  pulse: b => 0.3 + 0.7 * Math.exp(-5 * fr(b)),
  quarter: b => fr(b) < 0.5 ? 1 : 0,
  eighth: b => fr(b * 2) < 0.5 ? 1 : 0,
  sixteenth: b => fr(b * 4) < 0.5 ? 1 : 0,
  offbeat: b => fr(b) >= 0.5 ? 1 : 0.15,
  triplet: b => fr(b * 3) < 0.5 ? 1 : 0,
  tresillo: b => [0, 3, 6].includes(Math.floor(fr(b / 2) * 8)) ? 1 : 0.1,     // 3-3-2 over two beats
  gallop: b => [0, 2, 3].includes(Math.floor(fr(b) * 4)) ? 1 : 0,
  swell: b => 0.35 + 0.65 * (0.5 - 0.5 * Math.cos(fr(b / 4) * TAU)),
};
const MASKS = {
  all: () => true,
  alt: (i, n, b) => (i + Math.floor(b)) % 2 === 0,                              // odd and even beams trade beats
  wipe: (i, n, b) => i / Math.max(1, n - 1) <= fr(b / 4) * 1.15,                // beams join across the fan each bar
  centre: (i, n, b) => Math.abs(i / Math.max(1, n - 1) - 0.5) * 2 <= 0.15 + fr(b),   // from the middle out each beat
  random: (i, n, b) => hash(Math.floor(b * 4) * 7 + i * 3) < 0.6,
  thirds: (i, n, b) => i % 3 === ((Math.floor(b) % 3) + 3) % 3,
};
const COLOURS = {
  look: rgb => rgb,
  mono: (rgb, x, i, f) => hsl(f.hue),
  split: (rgb, x, i, f, side) => hsl(f.hue + (side > 0 ? 0.5 : 0)),              // each side its own colour
  gradient: (rgb, x, i, f) => hsl(f.hue + x * 0.33),
  cycle: (rgb, x, i, f, s, b) => hsl(f.hue + (((Math.floor(b) % 3) + 3) % 3) / 3), // three colours, a step a beat
  accent: (rgb, x, i, f, s, b) => fr(b / 4) < 0.06 ? WHITE : rgb,                  // white on every downbeat
  ice: (rgb, x, i) => i % 3 === 0 ? ICE : rgb,
};
const FILLS = ["roll", "snap", "lift", "freeze", "spin", "none"];
const BUILDS = {
  converge: { cue: "converge" }, rise: { cue: "rise" }, spinup: { cue: "tunnel", params: { R: 0.3 }, spinAmp: 5 },
  harproll: { cue: "harp", params: { n: 11 }, harpRoll: true }, countin: { cue: "fan", params: { n: 32 }, countIn: true },
  pyramid: { cue: "pyramid" }, lift: { cue: "sky", lift: true }, helix: { cue: "helix", spinAmp: 4 }, crown: { cue: "crown", spinAmp: 4 },
};
const BUILD_GATES = {
  double: p => p < 0.5 ? 2 : p < 0.75 ? 4 : p < 0.9 ? 8 : 16,
  triplets: p => p < 0.5 ? 3 : p < 0.8 ? 6 : 12,
  late: p => p < 0.75 ? 0 : p < 0.9 ? 8 : 16,
  ramp: p => Math.pow(2, Math.floor(p * 5)),
  none: () => 0,
};

let curSeed = null, trackSalt = 0;
const programs = new Map(), recent = [];
function track(seed) {
  if (seed === curSeed) return;
  curSeed = seed; trackSalt = (Math.random() * 2 ** 31) | 0; programs.clear();
}
function lookPrefs(L) {
  const s = new Set();
  for (const k of ["intro", "groove", "build", "breakdown", "drop"]) for (const [c] of L[k] || []) s.add(c);
  return s;
}
function chooseCue(r, pool, L, avoid) {
  const pref = lookPrefs(L), old = new Set(recent.flatMap(p => p.mains));
  return pickW(r, pool.filter(c => !avoid.includes(c)).map(c => [c, (pref.has(c) ? 3 : 1) * (old.has(c) ? 0.35 : 1)]));
}
function phrase(r, sec, L, prev, k, last) {
  const calm = sec === "intro" || sec === "breakdown";
  const main = chooseCue(r, POOL[sec], L, prev ? [prev.main] : []);
  const layerP = calm ? 0.25 : sec === "groove" ? 0.3 : 0.25 + 0.2 * k + (last ? 0.6 : 0);
  const layer = r() < layerP ? chooseCue(r, POOL.layer, L, [main]) : null;
  const gates = calm ? ["none", "swell", "pulse"] : sec === "groove" ? ["none", "pulse", "quarter", "offbeat", "eighth", "gallop", "tresillo", "triplet"]
    : ["none", "pulse", "quarter", "eighth", "sixteenth", "offbeat", "triplet", "tresillo", "gallop"];
  return {
    main, layer, mp: PARAMS[main](r), lp: layer ? { ...PARAMS[layer](r), dim: 0.5 } : null,
    gate: L.dropGate && sec === "drop" && r() < 0.4 ? (L.dropGate === 4 ? "sixteenth" : "eighth") : pick(r, gates),
    mask: r() < 0.5 ? "all" : pick(r, Object.keys(MASKS)),
    colour: pickW(r, [["look", 4], ["mono", 1], ["split", 1.5], ["gradient", 1.5], ["cycle", calm ? 0.3 : 1.5], ["accent", calm ? 0 : 1], ["ice", 1]]),
    motion: pickW(r, [["mirror", 2], ["parallel", 1], ["canon", 1]]),
    rate: calm ? pick(r, [0.5, 1]) : pick(r, [0.5, 1, 1, 2]),
    fill: calm ? pick(r, ["none", "lift", "freeze"]) : pick(r, FILLS),
    seed: (r() * 1e9) | 0,
  };
}
function compose(key, sec, f, L) {
  if (programs.has(key)) return programs.get(key);
  let best = null, bestScore = Infinity;
  for (let tries = 0; tries < 6; tries++) {             // a few candidates; keep the one least like the recent ones
    const r = rng(strHash(key) ^ trackSalt ^ (tries * 0x9E3779B9));
    let p;
    if (sec === "build") {
      const style = pick(r, Object.keys(BUILDS)), b = BUILDS[style];
      p = { sec, style, ...b, gateCurve: pick(r, Object.keys(BUILD_GATES)), colour: pick(r, ["look", "mono", "gradient", "split", "ice"]),
            whiten: r() < 0.6, layer: r() < 0.4 ? pick(r, ["starfield", "crown", "lissajous"]) : null, motion: pickW(r, [["mirror", 3], ["parallel", 1]]),
            mains: [b.cue], seed: (r() * 1e9) | 0 };
      p.mp = { ...PARAMS[b.cue](r), ...(b.params || {}) };
    } else {
      const k = f.ordinal || 0, finale = !!f.finale, count = sec === "drop" ? 4 : 2, ph = [];
      for (let i = 0; i < count; i++) ph.push(phrase(r, sec, L, ph[i - 1], k, finale && i === count - 1));
      if (sec !== "drop" && r() < 0.5) ph[1] = { ...ph[0], fill: ph[1].fill, layer: ph[1].layer, lp: ph[1].lp };   // grooves often hold their cue for 8 bars
      p = { sec, phrases: ph, span: sec === "drop" ? 16 : 16, mains: ph.map(x => x.main),
            opener: sec === "drop" ? pick(r, ["burst", "slam", "curtain", "shatter", "crown", "pyramid", "none"]) : null,
            boost: sec === "drop" ? 1 + 0.2 * k + (finale ? 0.3 : 0) : 1 };
    }
    const sig = p.mains.join(","), score = recent.reduce((s, q) => s + (q.sig === sig ? 10 : 0) + p.mains.filter(m => q.mains.includes(m)).length, 0);
    p.sig = sig;
    if (score < bestScore) { best = p; bestScore = score; }
    if (score === 0) break;
  }
  programs.set(key, best); recent.push(best); if (recent.length > 10) recent.shift();
  if (programs.size > 64) programs.delete(programs.keys().next().value);
  return best;
}
const OPENERS = {
  burst: ["burst", { n: 32 }], slam: ["fan", { n: 56 }], curtain: ["sky", {}], shatter: ["chase", { n: 20, div: 4 }],
  crown: ["crown", { n: 32, spin: 2 }], pyramid: ["pyramid", { n: 21 }],
};
const at = (f, beat) => ({ ...f, beat, frac: fr(beat) });

function draw(cue, params, fe, ctx, base, scale) {
  const o = { ...base, ...params };
  if (o.n && scale !== 1) o.n = Math.max(2, Math.min(72, Math.round(o.n * scale)));
  return CUES[cue](fe, ctx, o);
}

export function laserFrame(lookId, f, ctx) {
  track(ctx.seed);
  const id = resolveLook(lookId, ctx.seed ^ trackSalt), sec = SECTION[f.scene];
  const off = { cue: "off", level: 0, beams: [], sheet: null };
  if (!sec || f.black) return off;                                          // IDLE, PREDROP blackout
  if (sec === "drop" && f.since < 0.25) return off;                         // the drop hit belongs to the strobe
  if (id === "classic") return { cue: "classic", level: sec === "drop" ? 1 : sec === "intro" || sec === "breakdown" ? 0.45 : 0.9, sheet: null, ...CUES.classic(f, ctx, {}) };
  const L = LOOKS[id], pal = PAL[L.pal], energy = f.energy ?? 0.6, prog = f.progress || 0;
  const scale = (0.75 + 0.5 * Math.min(1, Math.max(0, energy)));
  let key, rel, base = 0;
  if (sec === "drop") { base = Math.round(f.beat - f.since); key = `drop:${base}`; }
  else if (sec === "build") key = `build:${Number.isFinite(f.dropAt) ? Math.round(f.dropAt) : Math.floor(f.beat / 64)}`;
  else { base = Math.floor(f.beat / 32) * 32; key = `${sec}:${base}`; }
  const P = compose(key, sec, f, L);
  rel = f.beat - base;

  let beams = [], sheet = null, level = LEVEL[sec], names, motion, colour, ph = null, fillK = -1;
  if (sec === "build") {
    const o = { pal, tight: 1 - 0.65 * prog, spin: 1 + (P.spinAmp || 2) * prog, seed: P.seed };
    const mp = { ...P.mp };
    if (P.harpRoll) mp.rate = [1, 2, 4, 8, 16][Math.min(4, Math.floor(prog * 5))];
    let out = draw(P.cue, mp, f, ctx, o, scale);
    beams = out.beams; sheet = out.sheet || null;
    if (P.countIn) beams = beams.slice(0, Math.max(1, Math.ceil(beams.length * (0.08 + 0.92 * prog))));
    if (P.lift) { const up = 0.45 * prog; beams = beams.map(b => ({ ...b, pitch: b.pitch + up })); if (sheet) sheet = { ...sheet, dirs: sheet.dirs.map(([y, p]) => [y, p + up]) }; }
    if (P.layer && prog > 0.5) { const l = draw(P.layer, { ...PARAMS[P.layer](rng(P.seed)), dim: 0.5 }, f, ctx, o, scale); beams = beams.concat(l.beams.map(b => ({ ...b, rgb: b.rgb.map(v => v * 0.5) }))); sheet = sheet || l.sheet || null; }
    if (P.whiten) beams = beams.map(b => ({ ...b, rgb: b.rgb.map(v => lerp(v, 1, prog * 0.7)) }));
    const g = BUILD_GATES[P.gateCurve](prog);
    level *= 0.6 + 0.4 * prog;
    if (g && fr(f.beat * g) >= 0.5) level = 0;
    names = `${P.style} build`; motion = P.motion; colour = P.colour;
  } else {
    const idx = Math.min(P.phrases.length - 1, Math.floor(Math.max(0, rel) / P.span)), within = rel - idx * P.span;
    ph = P.phrases[idx]; motion = ph.motion; colour = ph.colour;
    fillK = within >= P.span - 2 ? (within - (P.span - 2)) / 2 : -1;
    let fe = f;
    if (motion === "canon" && ctx.side > 0) fe = at(fe, fe.beat - 2);
    if (fillK >= 0 && ph.fill === "freeze") fe = at(fe, base + idx * P.span + P.span - 2);
    if (ph.rate !== 1) fe = at(fe, fe.beat * ph.rate);
    const o = { pal, tight: 1, spin: fillK >= 0 && ph.fill === "spin" ? -2 : 1, seed: ph.seed };
    const sc = scale * (P.boost || 1);
    let main = ph.main, mp = ph.mp;
    if (sec === "drop" && rel < 4 && P.opener && P.opener !== "none") [main, mp] = OPENERS[P.opener];
    const out = draw(main, mp, fe, ctx, o, sc);
    beams = out.beams; sheet = out.sheet || null; level *= out.fade ?? 1;
    if (ph.layer && !(sec === "drop" && rel < 4)) {
      const l = draw(ph.layer, ph.lp, fe, ctx, o, sc);
      beams = beams.concat(l.beams.map(b => ({ ...b, rgb: b.rgb.map(v => v * 0.55) })));
      sheet = sheet || l.sheet || null;
    }
    if (motion === "parallel" && ctx.side > 0 && SYM.has(main)) { beams = beams.map(b => ({ ...b, yaw: -b.yaw })); }
    if (fillK >= 0 && ph.fill === "lift") beams = beams.map(b => ({ ...b, pitch: b.pitch + 0.3 * fillK }));
    const mask = MASKS[ph.mask];
    beams = beams.filter((b, i) => mask(i, beams.length, f.beat));
    names = ph.layer ? `${main} + ${ph.layer}` : main;
    if (sec === "groove" || sec === "drop") level *= 0.72 + 0.28 * Math.exp(-6 * f.frac);
    level *= GATES[ph.gate](f.beat);
    if (fillK >= 0 && ph.fill === "roll") level *= fr(f.beat * (fillK < 0.5 ? 4 : 8)) < 0.5 ? 1 : 0;
    if (fillK >= 0.75 && ph.fill === "snap") level = 0;
  }
  const cmap = COLOURS[colour] || COLOURS.look, n = beams.length;
  beams = beams.map((b, i) => {
    const dim = Math.max(b.rgb[0], b.rgb[1], b.rgb[2]);                    // keep a cue's own dimming (harp, layers)
    let rgb = colour === "look" ? b.rgb : cmap(b.rgb, n > 1 ? i / (n - 1) : 0.5, i, f, ctx.side, f.beat);
    if (colour !== "look" && colour !== "accent" && colour !== "ice") rgb = rgb.map(v => v * dim);
    return { ...b, rgb: noYellow(rgb) };
  });
  if (sheet) sheet = { ...sheet, rgbA: noYellow(sheet.rgbA), rgbB: noYellow(sheet.rgbB) };
  return { cue: `${id} · ${names}${motion && motion !== "mirror" ? ` · ${motion}` : ""}`, level: level * (f.intensity ?? 0.8) / 0.8, beams: beams.slice(0, 72), sheet };
}

// ------------------------------------------------------------------ leg-pyramid lasers
// The real red lasers on the leg pyramids are on/off. Each drop gets its own rhythm per 4-bar
// phrase (held for the first bar, then from the list below, never the same twice running), so the
// sky beams don't repeat drop to drop. looks.py (pyramid_laser) does the same on the brain.
export const PYR_LASER = ["kick", "one", "offbeat", "gallop", "triplet", "tresillo", "bars", "eighths"];
export function pyramidLaserOn(f, seed = 0) {
  if (f.black || f.scene !== "DROP") return false;
  if (f.since < 4) return true;
  const b = f.beat, start = Math.round(f.beat - f.since), phr = Math.floor(f.since / 16);
  let last = -1, pat = 0;
  for (let i = 0; i <= phr; i++) { pat = Math.floor(hash(start * 0.37 + i * 13.1 + (seed % 997)) * (PYR_LASER.length - 1)); if (pat >= last && last >= 0) pat++; last = pat; }
  switch (PYR_LASER[pat]) {
    case "kick": return fr(b) < 0.5;
    case "one": return fr(b / 4) < 0.125;
    case "offbeat": return fr(b) >= 0.5 && fr(b) < 0.85;
    case "gallop": return [0, 2, 3].includes(Math.floor(fr(b) * 4));
    case "triplet": return fr(b * 3) < 0.5;
    case "tresillo": return [0, 3, 6].includes(Math.floor(fr(b / 2) * 8));
    case "bars": return fr(b / 8) < 0.5 ? true : fr(b) < 0.5;
    default: return fr(b * 2) < 0.5;
  }
}
