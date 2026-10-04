// Track: the waveform of the song that's actually playing. The visuals service follows the
// live deck and hands every page its rekordbox waveform, resampled per beat, so wave(beat)
// gives (height, bass, mids, highs) anywhere in the track (see render.js). Modes:
//   0 Terrain: Unknown Pleasures made of the song. Each ridge is a bar; the front ridge is the
//     bar playing now and the bars to come roll in from the distance, so you see drops coming
//   1 Scroll: what the DJ sees on the decks (the Decks page's waveform): the colour waveform at
//     full detail sliding past a playhead, played part dimmed, beat and bar ticks top and bottom,
//     bar numbers
//   2 Ring: the current stretch of the song wrapped round a circle, a hand sweeping round it
//   3 Meters: bass, mids and highs as three columns
// At home (no decks) it plays a captured sample or a demo track, looped.
// Params are p_* uniforms; ranges and defaults are in track.json.
uniform float p_mode, p_lines, p_window, p_play, p_amp, p_gamma, p_width, p_glow, p_past,
              p_colour, p_hue, p_sat, p_follow, p_beat, p_dwin, p_exact;

#define TAU 6.2831853

float H(float beat) { return pow(wave(beat).x, p_gamma); }

// The track's own colour at a beat (red bass, green mids, blue highs), brightened.
vec3 trNoYellow(vec3 c);
vec3 trackCol(float beat) {
  vec3 c = wave(beat).yzw;
  return trNoYellow(c / max(max(c.r, max(c.g, c.b)), 0.25));
}

// No yellow on the rig, without losing rekordbox's colour detail: hues from red-orange to green
// are squeezed so they skip amber..chartreuse (34-90 degrees), as the lights do (looks.no_yellow),
// so red -> orange -> green still shades through every step; only the yellow stretch is gone.
vec3 trNoYellow(vec3 c) {
  float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), d = mx - mn;
  if (d <= 1e-4 || mx <= 0.0) return c;
  float h = (mx == c.r ? mod((c.g - c.b) / d, 6.0) : mx == c.g ? (c.b - c.r) / d + 2.0 : (c.r - c.g) / d + 4.0) / 6.0;
  if (h <= 0.03 || h >= 0.36) return c;
  float o = 0.03 + (h - 0.03) / 0.33 * 0.175;
  return hsv(o >= 0.095 ? o + 0.155 : o, d / mx, mx);
}
// Bar numbers: a 3x5 pixel font, one digit's bits row by row from the top left.
float digitBits(float d) {
  if (d < 0.5) return 31599.0; if (d < 1.5) return 25751.0; if (d < 2.5) return 29671.0;
  if (d < 3.5) return 29647.0; if (d < 4.5) return 23497.0; if (d < 5.5) return 31183.0;
  if (d < 6.5) return 31215.0; if (d < 7.5) return 29257.0; if (d < 8.5) return 31727.0;
  return 31695.0;
}
float digit(vec2 q, float d) {                       // q: 0..1 across the digit, y down
  if (q.x < 0.0 || q.x >= 1.0 || q.y < 0.0 || q.y >= 1.0) return 0.0;
  float bit = 14.0 - (floor(q.y * 5.0) * 3.0 + floor(q.x * 3.0));
  return mod(floor(digitBits(d) / pow(2.0, bit)), 2.0);
}
float number(vec2 q, float n) {                      // q in digit widths (a gap of a third between), y down
  float nd = n < 9.5 ? 1.0 : n < 99.5 ? 2.0 : 3.0;
  float i = floor(q.x / 1.34);
  if (i < 0.0 || i >= nd) return 0.0;
  float dv = mod(floor(n / pow(10.0, nd - 1.0 - i) + 0.001), 10.0);
  return digit(vec2(q.x - i * 1.34, q.y), dv);
}

vec3 content(vec2 uv) {
  float t = u_beat;
  float k = kick() * p_beat;
  float A = u_aspect;
  float px = u_px;
  float w = max(p_width, px);
  vec3 tint = trNoYellow(hsv(p_hue + (p_follow > 0.5 ? u_hue : 0.0), p_sat, 1.0));
  float amp = p_amp * (1.0 + 0.3 * k);
  vec3 col = vec3(0.0);

  if (p_mode < 0.5) {
    // Terrain: ridge j (0 = furthest) shows bar (now + N-1-j); all slide forward over each bar.
    float N = max(2.0, floor(p_lines));
    float barNow = floor((t - 1.0) / 4.0);
    float slide = fract((t - 1.0) / 4.0);
    float top = 0.12, bot = 0.92;
    float x0 = 0.18, x1 = 0.82;                             // the ridges span the middle
    float u = (uv.x - x0) / (x1 - x0);
    float inX = step(0.0, u) * step(u, 1.0);
    float e = 0.004;
    for (int jj = 0; jj < 64; jj++) {
      float j = float(jj);
      if (j > N) break;
      float base = mix(top, bot, (j + slide) / N);
      if (uv.y < base - amp * 1.05 - w) continue;
      if (base < uv.y - w - px) continue;
      float bar = barNow + (N - j);
      float bstart = bar * 4.0 + 1.0;
      float env = sin(3.1415927 * clamp(u, 0.0, 1.0));
      float hh = inX * H(bstart + 4.0 * u) * env * amp;
      float h2 = inX * H(bstart + 4.0 * (u + e)) * sin(3.1415927 * clamp(u + e, 0.0, 1.0)) * amp;
      float slope = (h2 - hh) / (e * (x1 - x0));
      float d = (uv.y - (base - hh)) / sqrt(1.0 + slope * slope);
      col *= 1.0 - smoothstep(-px, px, d);
      float line = 1.0 - smoothstep(w - px, w + px, abs(d));
      float near = 1.0 - (N - j) / N;                        // front ridges brighter
      vec3 lc = p_colour > 0.5 ? tint : mix(vec3(1.0), trackCol(bstart + 4.0 * u), 0.8);
      col = max(col, lc * line * (0.35 + 0.65 * near));
    }
  } else if (p_mode < 1.5) {
    // Scroll: the deck's view. Each pixel column shows the loudest rekordbox frame in it, in its
    // own colour, mirrored about the centre line; the played part is dimmed (the decks draw it at
    // 55% over the background); white ticks on every beat top and bottom, longer on the bar, with
    // the bar's number; a white playhead with a marker.
    vec3 bg = vec3(0.031, 0.031, 0.039);
    float win = max(p_dwin, 1.0);
    float b = t + (uv.x - p_play) * win;                        // the beat at this column
    float colW = win * px / A;                                   // one pixel column, in beats
    vec4 s = vec4(0.0);
    float h0 = 0.0, h1 = 0.0;                                    // the height at this column's edges, for a smooth top
    if (u_wv.w > 0.0) {
      float n = u_wv.w * u_wv.z;
      float i0 = (b - 1.0) * u_wv.z, i1 = (b - 1.0 + colW) * u_wv.z;
      for (int kk = 0; kk < 6; kk++) {
        float i = floor(mix(i0, i1, float(kk) / 5.0));
        if (u_wloop > 0.5) i = mod(i, n);
        if (i < 0.0 || i > n - 1.0) continue;
        vec4 v = waveTexel(i);
        if (v.x >= s.x) s = v;
      }
      h0 = wave(b).x; h1 = wave(b + colW).x;
    }
    float hspan = min(p_amp * 3.0, 0.48) * (1.0 + 0.15 * k);
    // rekordbox's RGB waveform: each moment in its own colour, red bass, green mids, blue highs.
    // Vivid like rekordbox: each colour brought up towards full strength, its hue kept exactly.
    vec3 raw = s.yzw / max(max(s.y, max(s.z, s.w)), 0.3);
    raw = mix(s.yzw, raw, 0.75);
    vec3 c = p_colour > 0.5 ? tint * (0.4 + 0.6 * s.x) : (p_exact > 0.5 ? raw : trNoYellow(raw));
    // The top edge: when the column covers less than a frame, follow the waveform between frames
    // (interpolated, anti-aliased) rather than stepping; wider columns keep their loudest frame.
    float hh = colW * u_wv.z < 1.0 ? max(mix(h0, h1, 0.5), 0.0) : s.x;
    float dy = abs(uv.y - 0.5) - hh * hspan;
    col = mix(bg, vec3(0.09, 0.09, 0.098), step(abs(uv.y - 0.5), px * 0.5));       // the centre line
    col = mix(col, mix(bg, c, b < t ? p_past : 1.0), clamp(0.5 - dy / px, 0.0, 1.0));
    // The beat grid: which beat line is nearest, is it a bar line, and how far away in pixels.
    float D = floor(barBeat() + 0.5);                            // the downbeat of the bar playing now
    float bn = floor(b + 0.5);
    float dx = abs(b - bn) / win * A / px;
    float isBar = 1.0 - step(0.5, mod(bn - D, 4.0));
    float th = isBar > 0.5 ? 0.135 : 0.075;
    float tick = step(dx, isBar > 0.5 ? 1.0 : 0.5) * (step(uv.y, th) + step(1.0 - th, uv.y));
    col = mix(col, vec3(1.0), tick * (isBar > 0.5 ? 1.0 : 0.7));
    // The bar's number, just right of its line at the top.
    float bb = D + 4.0 * floor((b - D) / 4.0);                    // the bar line at or before here
    float barNo = u_bar + (bb - D) / 4.0;
    float dh = 0.075, cw = dh * 0.6;
    vec2 q = vec2(((b - bb) / win * A - 3.0 * px) / cw, (uv.y - 0.16) / dh);
    if (barNo >= 1.0) col = mix(col, vec3(1.0), number(q, barNo));
    // The playhead, with its marker at the top.
    float pxd = abs(uv.x - p_play) * A / px;
    col = mix(col, vec3(1.0), step(pxd, 1.0));
    float mk = 0.045;
    col = mix(col, vec3(1.0), step(uv.y, mk) * step(pxd * px, (mk - uv.y) * 0.75));
    return col;
  } else if (p_mode < 2.5) {
    // Ring: the current window of beats round a circle, starting at the top, clockwise.
    vec2 p = (uv - 0.5) * vec2(A, 1.0);
    float r = length(p);
    float a = fract(atan(p.x, -p.y) / TAU);                   // 0 at the top, clockwise
    float win = max(4.0, floor(p_window));
    float start = floor((t - 1.0) / win) * win + 1.0;
    float b = start + a * win;
    float hh = H(b) * amp * 1.5;
    float r0 = 0.25;
    float d = abs(r - r0) - hh * 0.5 - w;
    float fill = 1.0 - smoothstep(-px, px, d);
    vec3 c = p_colour > 0.5 ? tint : trackCol(b);
    float done = b <= t ? 1.0 : p_past;
    col = c * fill * done + c * p_glow * 0.2 * exp(-max(d, 0.0) * 30.0) * done;
    float ah = (t - start) / win;                             // the hand
    float dh = abs(fract(a - ah + 0.5) - 0.5) * TAU * r;
    col += vec3(1.0) * (1.0 - smoothstep(px, px * 2.5, dh)) * step(r, r0 + amp) * step(r0 - amp, r);
  } else {
    // Meters: bass, mids, highs.
    vec4 s = wave(t);
    float i = floor(uv.x * 3.0);
    float lvl = i < 0.5 ? s.y : i < 1.5 ? s.z : s.w;
    lvl = pow(lvl, p_gamma) * (0.7 + 0.3 * k) * p_amp * 4.0;
    float lx = fract(uv.x * 3.0);
    float bar = step(0.12, lx) * step(lx, 0.88) * step(1.0 - lvl, uv.y);
    float seg = step(0.2, fract(uv.y * 24.0));               // LED segments
    vec3 c = p_colour > 0.5 ? tint : (i < 0.5 ? vec3(1.0, 0.2, 0.15) : i < 1.5 ? vec3(0.2, 1.0, 0.3) : vec3(0.25, 0.5, 1.0));
    col = c * bar * seg;
  }
  return (1.0 - exp(-col * 1.6)) * (0.85 + 0.15 * k);
}
