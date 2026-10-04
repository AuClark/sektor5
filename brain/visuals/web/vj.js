// Shared by the Visuals page (index.html) and the Launchpad (pad.html): musical rate values,
// the energy randomiser behind Calm / Groove / Drop, and the beat-quantised launcher.
//
// Vanilla, no build step, loaded with a plain <script> before the page's own code.

"use strict";

const VJ = (() => {

  // ---------------------------------------------------------------- musical rates
  // Everything is stored in cycles per beat, as everywhere else in the rig. A 1/4 note is one
  // beat, so rate 1; a 1/1 is a bar of four, so rate 0.25. Dotted (·) is half again as long,
  // a triplet (T) two thirds as long.
  const NOTES = (() => {
    const base = [[8, "8/1"], [4, "4/1"], [2, "2/1"], [1, "1/1"], [0.5, "1/2"],
                  [0.25, "1/4"], [0.125, "1/8"], [0.0625, "1/16"], [0.03125, "1/32"]];
    const out = [];
    for (const [bars, label] of base) {
      const beats = bars * 4;
      out.push({ cpb: 1 / beats, label });
      out.push({ cpb: 1 / (beats * 1.5), label: label + "·" });
      out.push({ cpb: 1 / (beats * 2 / 3), label: label + "T" });
    }
    return out.sort((a, b) => a.cpb - b.cpb);
  })();

  // Sketch speeds run backwards as well as forwards, and nought means stopped, so those get the
  // whole ladder. An automation rate only ever needs the forward half.
  const RNOTES = [...NOTES.slice().reverse().map(n => ({ cpb: -n.cpb, label: "-" + n.label })),
                  { cpb: 0, label: "stop" }, ...NOTES];
  const HZ = [0.02, 0.05, 0.1, 0.2, 0.33, 0.5, 1, 2, 3, 5, 8].map(v => ({ cpb: v, label: v + " Hz" }));

  const near = (list, v) => list.reduce((b, n) => Math.abs(n.cpb - v) < Math.abs(b.cpb - v) ? n : b, list[0]);
  const snapRate = v => near(RNOTES, v);

  // ---------------------------------------------------------------- energy
  // "Energy" means how busy the picture is: how fast things move, how many of them there are,
  // how hard the track drives them. Which way a parameter pushes comes from the sketch where it
  // says so ("energy": 1 busier, -1 calmer, 0 neither); otherwise it is a known mover, a known
  // settler, or simply randomised. A speed's energy is how fast it goes and not which way, so
  // its magnitude is aimed and the direction left to chance.
  //
  // Two kinds are never touched. "quality" buys frame rate, not looks, and a dice roll on it is
  // how you end up at nine frames a second on the projector. "fixed" is identity -- Hypnotoad's
  // collar and line weight, say: randomising those does not give you a different look, it gives
  // you something that is no longer the thing it is supposed to be.
  const BUSY = new Set(["aamt", "bamt", "camt", "bounce", "dance", "noodle", "boil", "film", "glow",
    "jitter", "twist", "spin", "zoom", "patspin", "patscale", "prop", "propodds", "pat", "detail",
    "cast", "density", "speed", "wspeed", "wspd", "gspeed", "flow", "orbit", "beat", "punch",
    "aliens", "legs", "kal", "rosette", "burst", "lines", "trees", "people", "glitch", "rays"]);
  const CALM = new Set(["fog", "bg", "swap", "far", "day", "climb"]);

  const isRate = p => p.kind === "rate";
  const skip = p => p.id === "follow" || p.kind === "quality" || p.kind === "fixed";
  const dirOf = p => p.energy !== undefined ? p.energy
    : (isRate(p) || BUSY.has(p.id)) ? 1 : CALM.has(p.id) ? -1 : 0;

  const quant = (p, v) => {
    v = isRate(p) ? snapRate(v).cpb : Math.round(v / p.step) * p.step;
    return Math.max(p.min, Math.min(p.max, v));
  };

  // A whole new set of values at the given energy (0 calm .. 1 full on). lo/hi come from the
  // caller so the ranges on the sliders are respected: nothing ever leaves them.
  function energyValues(params, lo, hi, e) {
    const out = {};
    for (const p of params) {
      if (skip(p)) continue;
      const a = lo(p), b = hi(p), dir = dirOf(p);
      let t;
      if (dir === 0) t = Math.random();
      else {
        const jit = 0.12 + 0.22 * e;
        t = Math.min(1, Math.max(0, (dir > 0 ? e : 1 - e) + (Math.random() - 0.5) * 2 * jit));
      }
      let v = a + t * (b - a);
      if (isRate(p) && a < 0 && b > 0) {
        const mag = Math.max(Math.abs(a), Math.abs(b)) * t;
        v = (Math.random() < 0.5 ? -1 : 1) * mag;
      }
      out[p.id] = quant(p, Math.max(a, Math.min(b, v)));
    }
    return out;
  }

  // Intensity: one fader, calm to full on, played live, and it has to look like one smooth thing
  // getting stronger. So it only touches "how strongly" settings: the track's grip on the picture
  // (the A / B / C drive amounts) and amplitudes like kick punch, glow, jitter, bounce. Never a
  // speed (a sketch works position out from beat x speed, so a new speed jumps things: Sisyphus's
  // beetle leaps), never a count or a choice (Labyrinth's walls, Inkwell's cast), never a look.
  // A sketch can opt a setting in or out with "intensity": true / false in its json.
  // Nothing is random: back and forth goes back and forth through the same pictures.
  const GAIN = new Set(["aamt", "bamt", "camt", "beat", "punch", "glow", "jitter", "glitch", "bounce", "dance",
    "boil", "rays", "surge", "lurch", "noodle"]);
  const smooth = p => p.max > p.min && (!p.step || (p.max - p.min) / p.step >= 20);
  const isGain = p => p.intensity === true || (p.intensity !== false && GAIN.has(p.id) && !isRate(p) && !skip(p) && smooth(p));
  function intensityValues(params, lo, hi, e) {
    const out = {};
    for (const p of params) {
      if (!isGain(p)) continue;
      const a = lo(p), b = hi(p);
      out[p.id] = quant(p, a + e * (b - a));
    }
    return out;
  }
  // Where the fader sits for a set of values: the same mapping read backwards, averaged.
  function intensityOf(params, lo, hi, cur = {}) {
    let sum = 0, n = 0;
    for (const p of params) {
      if (!isGain(p)) continue;
      const a = lo(p), b = hi(p); if (b === a) continue;
      sum += Math.max(0, Math.min(1, ((cur[p.id] ?? p.default) - a) / (b - a))); n++;
    }
    return n ? sum / n : 0.5;
  }

  // The fader itself, the same on every page that has one: the whole bar is the control (drag or
  // tap anywhere on it), a fill that breathes on the beat, arrow keys for a laptop. onInput gets
  // 0..1 while it moves, at most every 40 ms; set(v) moves it from outside (ignored mid-drag).
  // The fader itself, the same on every page that has one: the whole bar is the control (drag or
  // tap anywhere on it), a fill that breathes on the beat, arrow keys for a laptop. What it sends
  // glides after the finger (about a quarter of a second to get there), so even a tap from one end
  // to the other is a sweep, not a jump. onInput gets 0..1 at most every 40 ms; set(v) moves it
  // from outside (ignored while it's being played).
  function fader(el, onInput, label = "Intensity") {
    el.classList.add("s5fader"); el.tabIndex = 0; el.setAttribute("role", "slider");
    el.setAttribute("aria-label", label); el.setAttribute("aria-valuemin", 0); el.setAttribute("aria-valuemax", 100);
    el.innerHTML = `<div class="f"></div><div class="t"><span>${label}</span><b>–</b></div>`;
    const fill = el.querySelector(".f"), num = el.querySelector("b");
    let target = 0.5, out = 0.5, busy = false, gliding = false, last = 0, t0 = 0;
    const paint = x => { fill.style.width = (x * 100).toFixed(1) + "%"; num.textContent = Math.round(x * 100); el.setAttribute("aria-valuenow", Math.round(x * 100)); };
    function glide(now) {
      const dt = Math.min(0.1, (now - (t0 || now)) / 1000); t0 = now;
      out += (target - out) * (1 - Math.exp(-dt / 0.08));           // eased: ~95% there in a quarter second
      if (Math.abs(target - out) < 0.002) out = target;
      if (now - last > 40 || out === target) { last = now; onInput(out); }
      if (out !== target || busy) requestAnimationFrame(glide); else { gliding = false; t0 = 0; }
    }
    const go = x => { target = x; paint(x); if (!gliding) { gliding = true; requestAnimationFrame(glide); } };
    const at = e => { const r = el.getBoundingClientRect(); return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)); };
    el.addEventListener("pointerdown", e => { busy = true; el.setPointerCapture(e.pointerId); el.classList.add("drag"); go(at(e)); });
    el.addEventListener("pointermove", e => { if (busy) go(at(e)); });
    for (const ev of ["pointerup", "pointercancel"]) el.addEventListener(ev, () => { busy = false; el.classList.remove("drag"); });
    el.addEventListener("keydown", e => { const d = { ArrowRight: .05, ArrowUp: .05, ArrowLeft: -.05, ArrowDown: -.05 }[e.key];
      if (d) { e.preventDefault(); e.stopPropagation(); go(Math.max(0, Math.min(1, target + d))); } });
    paint(target);
    return {
      set: x => { if (!busy && !gliding && x != null && Math.abs(x - target) > 0.004) { target = out = x; paint(x); } },
      beat: f => el.style.setProperty("--pulse", f ? Math.pow(1 - f.frac, 3).toFixed(3) : 0),
      get value() { return target; }, get busy() { return busy || gliding; },
    };
  }

  // The track's waveform, for whoever is running the visuals: what the audio is doing and what's
  // coming. It's a monitor, not part of the picture, so it sits in its own panel under the preview
  // (never over it) and says so. On or off by one setting shared by every page that has it (Focus
  // and the Visuals page). The track scrolls past a playhead a third of the way in, bars marked,
  // bass in orange, what's been played dimmed. It reads the same per-beat waveform the sketches do
  // (MapRenderer.wave), on the same beat clock. Zoom: scroll wheel, pinch, or the − / + buttons,
  // from 4 beats across to 64 (remembered).
  const WAVE_KEY = "s5wavepv", ZOOM_KEY = "s5wavezoom";
  const waveOn = v => {
    if (v !== undefined) { localStorage.setItem(WAVE_KEY, v ? "1" : "0"); dispatchEvent(new Event("s5wavepv")); }
    const on = localStorage.getItem(WAVE_KEY) === "1";
    document.documentElement.classList.toggle("s5wave-on", on);
    return on;
  };
  addEventListener("storage", e => { if (e.key === WAVE_KEY) { waveOn(); dispatchEvent(new Event("s5wavepv")); } });
  function waveStrip(after, R) {
    const box = document.createElement("div"); box.className = "s5wavebox";
    box.innerHTML = `<div class="hd"><span class="tag">Audio monitor <i>· only here, not on the projector</i></span>
      <span class="zoom"><button type="button" data-z="1.5" aria-label="Zoom out">−</button><b></b><button type="button" data-z="0.667" aria-label="Zoom in">+</button></span></div>
      <div class="s5wv"><canvas></canvas></div>`;
    after.insertAdjacentElement("afterend", box);
    const cv = box.querySelector("canvas"), g = cv.getContext("2d"), zl = box.querySelector(".zoom b");
    let beats = Math.max(4, Math.min(64, +localStorage.getItem(ZOOM_KEY) || 16));
    const zoom = k => { beats = Math.max(4, Math.min(64, beats * k)); localStorage.setItem(ZOOM_KEY, beats.toFixed(2)); };
    box.querySelectorAll("[data-z]").forEach(b => b.onclick = () => zoom(+b.dataset.z));
    box.addEventListener("wheel", e => { e.preventDefault(); zoom(Math.exp(e.deltaY * 0.0025)); }, { passive: false });
    const pts = new Map(); let pinch = 0;
    box.addEventListener("pointerdown", e => { if (e.target.closest("button")) return; pts.set(e.pointerId, e.clientX); box.setPointerCapture(e.pointerId); });
    box.addEventListener("pointermove", e => {
      if (!pts.has(e.pointerId)) return; pts.set(e.pointerId, e.clientX);
      if (pts.size === 2) { const [a, b] = [...pts.values()], d = Math.abs(a - b); if (pinch) zoom(pinch / Math.max(d, 1)); pinch = d; }
    });
    for (const ev of ["pointerup", "pointercancel"]) box.addEventListener(ev, e => { pts.delete(e.pointerId); pinch = 0; });
    box.style.touchAction = "pan-y";
    waveOn();
    return f => {
      if (!document.documentElement.classList.contains("s5wave-on")) return;
      zl.textContent = Math.round(beats / 4 * 10) / 10 + " bars";
      const dpr = Math.min(2, devicePixelRatio || 1), W = Math.round(cv.clientWidth * dpr), H = Math.round(cv.clientHeight * dpr);
      if (!W || !H) return;
      if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; }
      g.clearRect(0, 0, W, H);
      const wv = R.wave, px = wv && wv.px, n = wv ? wv.beats * wv.spb : 0, mid = H * 0.5, amp = H * 0.42, head = Math.round(W * 0.33);
      if (!f || !px || !n) { g.fillStyle = "rgba(255,255,255,.4)"; g.font = `500 ${11 * dpr}px system-ui, sans-serif`;
        g.textAlign = "center"; g.fillText("Waiting for a track", W / 2, mid + 4 * dpr); g.textAlign = "left"; return; }
      const at = beat => { let i = Math.floor((beat - 1) * wv.spb); if (wv.loop) i = ((i % n) + n) % n;
        return i < 0 || i >= n ? null : i * 4; };
      const step = Math.max(1, Math.round(2 * dpr)), gap = step > 2 ? 1 : 0, off = f.beat - barBeat(f);
      for (let x = 0; x < W; x += step) {
        const o = at(f.beat + (x - head) / W * beats); if (o === null) continue;
        const hgt = Math.min(1, Math.sqrt(px[o] / 255) * 1.15), bass = px[o + 1] / 255, past = x < head;
        g.fillStyle = past ? "rgba(255,255,255,.22)" : "rgba(255,255,255,.7)";
        g.fillRect(x, mid - hgt * amp, step - gap, hgt * amp * 2);
        g.fillStyle = past ? "rgba(255,90,31,.4)" : "rgba(255,90,31,.95)";
        g.fillRect(x, mid - bass * hgt * amp, step - gap, bass * hgt * amp * 2);
      }
      const b0 = Math.ceil(f.beat - head / W * beats), b1 = f.beat + (W - head) / W * beats;
      for (let b = b0; b <= b1; b++) {
        const x = head + (b - f.beat) / beats * W, one = (((Math.round(b - off)) % 4) + 4) % 4 === 0;
        if (!one && beats > 32) continue;
        g.fillStyle = one ? "rgba(255,255,255,.4)" : "rgba(255,255,255,.12)";
        g.fillRect(Math.round(x), 0, dpr, H);
      }
      g.fillStyle = "#fff"; g.fillRect(head - dpr, 0, 2 * dpr, H);
    };
  }

  // The bar within the phrase, as the first beat of a beat counter (1 – – –): 1, 2, 3, 4 (a cycle of four beats each), then
  // round again. Tap it for how many bars it counts to: 4, 8, 16 or 2, one setting for every page.
  const BARS_KEY = "s5barsof", BARS = [4, 8, 16, 2];
  function barCounter(el) {
    el.classList.add("s5barn"); el.type = "button";
    let of = BARS.includes(+localStorage.getItem(BARS_KEY)) ? +localStorage.getItem(BARS_KEY) : 4, showOf = 0;
    const title = () => { el.title = `Bar ${el.dataset.n || 1} of ${of}. Tap to count to ${BARS[(BARS.indexOf(of) + 1) % BARS.length]}.`; el.setAttribute("aria-label", el.title); };
    el.addEventListener("click", e => { e.stopPropagation(); of = BARS[(BARS.indexOf(of) + 1) % BARS.length]; localStorage.setItem(BARS_KEY, of);
      showOf = performance.now() + 1200; dispatchEvent(new Event("s5barsof")); title(); });
    addEventListener("s5barsof", () => { of = +localStorage.getItem(BARS_KEY) || 4; });
    addEventListener("storage", e => { if (e.key === BARS_KEY) of = +e.newValue || 4; });
    title();
    // Right on a bar line the beat-in-bar and the beat can disagree for a frame; a new bar only shows
    // once it has held for ~120 ms, so the number never flickers.
    let shown = 1, cand = 1, since = 0;
    return f => {
      const raw = f ? (((Math.floor(barBeat(f) / 4) % of) + of) % of) + 1 : 1, now = performance.now();
      if (raw !== cand) { cand = raw; since = now; }
      if (cand !== shown && now - since > 120) shown = cand;
      const n = shown, txt = now < showOf ? `of ${of}` : String(n);
      if (el.textContent !== txt) { el.textContent = txt; el.dataset.n = n; title(); }
      // It is the bar's first beat too: lit (orange) for the whole of the 1, like the segment it replaces.
      el.classList.toggle("on", !!f && Math.round(f.bwb) === 1);
    };
  }

  // ---------------------------------------------------------------- quantised launch
  // A tap can either happen now or wait for the next musical boundary, so a change always lands
  // on the beat however sloppily it was hit. Nothing here touches the shader or the network
  // timing: it simply holds the action until the beat comes round.
  //
  // The boundaries are worked out on a beat counter shifted so every downbeat is a multiple of
  // four -- the same trick as barBeat() in the shaders -- so "1 bar" means the 1 and not
  // wherever the track happened to start.
  const GRID = [
    { beats: 0, label: "now" },
    { beats: 1, label: "1 beat" },
    { beats: 4, label: "1 bar" },
    { beats: 8, label: "2 bars" },
    { beats: 16, label: "4 bars" },
  ];

  function barBeat(f) {
    return f.beat - ((((Math.floor(f.beat) - (Math.round(f.bwb) - 1)) % 4) + 4) % 4);
  }

  class Launcher {
    constructor(frameOf) { this.frameOf = frameOf; this.grid = 4; this.pending = []; }

    // Returns null if it fired at once, otherwise how many beats until it does.
    launch(fn, tag) {
      const f = this.frameOf();
      if (!f || !this.grid) { fn(); return null; }
      const bb = barBeat(f);
      // A hair of slack, so a tap landing right on the line fires on that line and not a whole
      // bar later; a tap a fraction early is what a human hitting the 1 actually does.
      const at = this._next(bb);
      if (tag) this.pending = this.pending.filter(q => q.tag !== tag);   // one pending per slot
      this.pending.push({ at, fn, tag });
      return at - bb;
    }

    _next(bb) { return Math.ceil((bb + 0.08) / (this.grid || 1)) * (this.grid || 1); }

    cancel(tag) { this.pending = this.pending.filter(q => q.tag !== tag); }
    waiting(tag) { return this.pending.some(q => q.tag === tag); }

    // Call once a frame. Returns 0..1 through the wait for whatever is queued, for a progress ring.
    tick() {
      const f = this.frameOf();
      if (!f) return 0;
      const bb = barBeat(f);
      // The beat counter goes backwards when a new track is loaded. A pad queued for beat 300
      // would then wait out the whole new track, so anything now further off than one grid
      // step is put on the next boundary of the new count instead.
      for (const q of this.pending) if (q.at - bb > (this.grid || 1) + 0.1) q.at = this._next(bb);
      const due = this.pending.filter(q => q.at <= bb);
      if (due.length) {
        this.pending = this.pending.filter(q => q.at > bb);
        for (const q of due) q.fn();
      }
      if (!this.pending.length) return 0;
      const next = Math.min(...this.pending.map(q => q.at));
      return 1 - Math.max(0, Math.min(1, (next - bb) / this.grid));
    }
  }

  return { NOTES, RNOTES, HZ, near, snapRate, isRate, skip, dirOf, quant, energyValues, intensityValues, intensityOf, fader, waveStrip, waveOn, barCounter,
           GRID, barBeat, Launcher };
})();
