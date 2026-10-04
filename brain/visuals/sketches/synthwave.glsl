// Synthwave: the outrun sunset, built from the song that's playing. The floor is the track's own
// waveform (wave(): rekordbox's colour waveform at full detail, about 70 samples a beat) laid out as ridges in
// perspective, one beat a row across the screen, every sample across it, rows rolling in towards you in time so
// the beat under your feet is the beat you hear and the ones coming are out towards the horizon.
// The skyline is the whole track, start to end across the screen, the played part lit with a
// playhead where you are. Behind it a striped sun swells on the kick, over a neon grid.
// Ridges are coloured like rekordbox's waveform, in this sketch's palette: bass, mids and highs.
// Nothing goes yellow (sw_hue skips amber..chartreuse, as the lights do).
// Params are p_* uniforms; ranges and defaults are in synthwave.json.
uniform float p_rows, p_amp, p_width, p_camh, p_horizon, p_sun, p_stripes, p_skyline, p_grid,
              p_glow, p_punch, p_stars, p_pink, p_cyan, p_purple, p_hue, p_follow, p_bright;

float sw_h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float sw_hue(float h) {
  h = fract(h);
  if (h > 0.03 && h < 0.36) { float o = 0.03 + (h - 0.03) / 0.33 * 0.175; return o >= 0.095 ? o + 0.155 : o; }
  return h;
}
vec3 sw_col(float h, float s, float v) { return hsv(sw_hue(h), s, v); }
// The waveform at a beat, or a stand-in with no track (so the sketch never goes flat).
vec4 sw_wave(float b) {
  if (u_wv.w < 0.5) {
    float f = fract(b), k = exp(-7.0 * f);
    return vec4(0.25 + 0.5 * k + 0.15 * sw_h(vec2(floor(b * 32.0), 1.0)), k, 0.5 + 0.3 * sin(b * 0.7), 0.4 * exp(-12.0 * fract(b + 0.5)));
  }
  return wave(b);
}

vec3 content(vec2 uv) {
  float W = u_aspect * 0.5;
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
  p.y = -p.y;
  float px = u_px, k = kick();
  float H = p_hue + (p_follow > 0.5 ? u_hue - p_pink : 0.0);
  vec3 pink = sw_col(p_pink + H, 0.85, 1.0), cyan = sw_col(p_cyan + H, 0.75, 1.0), purple = sw_col(p_purple + H, 0.8, 1.0);
  float yh = p_horizon;
  float arc = dropArc();

  // ---- sky: deep violet down to a hot pink haze at the horizon, a few stars
  vec3 col = mix(purple * 0.35 + pink * 0.25, vec3(0.03, 0.01, 0.07), smoothstep(yh, 0.55, p.y));
  vec2 sg = floor(p * 70.0), sf = fract(p * 70.0) - 0.5;
  col += p_stars * step(0.93, sw_h(sg)) * smoothstep(0.08, 0.0, length(sf)) * smoothstep(yh + 0.15, 0.45, p.y) * (0.6 + 0.4 * sin(u_beat * 3.0 + sw_h(sg + 3.0) * 20.0));

  // ---- the sun: pink at the top to red-orange, cut by bands that drift down
  vec2 sc = vec2(0.0, yh + 0.2 * p_sun);
  float sr = 0.24 * p_sun * (1.0 + 0.04 * p_punch * k);
  float sd = length(p - sc) - sr;
  float sy = (p.y - sc.y) / sr;                                     // -1 bottom .. 1 top
  vec3 sunc = mix(sw_col(0.02 + H, 0.9, 1.0), sw_col(0.93 + H, 0.65, 1.0), smoothstep(-0.9, 0.9, sy));
  float band = fract(sy * 5.0 * p_stripes + u_beat / 8.0);
  float gap = sy < 0.15 ? step(band, 0.15 + 0.35 * (0.15 - sy)) : 0.0;
  col += pink * 0.35 * exp(-max(sd, 0.0) * 9.0) * (0.8 + 0.4 * p_punch * k);
  col = mix(col, sunc, clamp(0.5 - sd / px, 0.0, 1.0) * (1.0 - gap));

  // ---- the skyline: the whole track, start to end, played part lit, playhead where we are
  if (p_skyline > 0.0 && p.y >= yh - 0.01) {
    float beats = max(u_wv.w, 256.0);
    float bx = 1.0 + (p.x / W * 0.5 + 0.5) * (beats - 1.0);
    float hh = max(max(sw_wave(bx).x, sw_wave(bx + 0.5).x), sw_wave(bx - 0.5).x);
    float top = yh + 0.11 * p_skyline * hh;
    float played = step(bx, u_beat);
    vec3 sky = mix(vec3(0.05, 0.02, 0.1), mix(purple * 0.25, cyan * 0.45, played), 0.8);
    col = mix(col, sky, clamp(0.5 - (p.y - top) / px, 0.0, 1.0));
    col += mix(purple, cyan, played) * 0.8 * exp(-abs(p.y - top) / (2.0 * px)) * step(yh, p.y);
    float hx = ((clamp(u_beat, 1.0, beats) - 1.0) / (beats - 1.0) * 2.0 - 1.0) * W;
    col += vec3(0.9, 0.95, 1.0) * exp(-abs(p.x - hx) / (1.5 * px)) * step(yh, p.y) * step(p.y, top + 0.02) * (0.6 + 0.4 * k);
  }

  // ---- the floor: a neon grid, with the waveform's ridges rolling in over it
  if (p.y < yh) {
    float f = 1.0, ch = p_camh * (1.0 - 0.25 * arc);
    float zf = ch * f / max(yh - p.y, 1e-4);                          // depth of the flat floor here
    float wx = p.x * zf / f;
    float gd = abs(fract(wx / 0.5 + 0.5) - 0.5) * 0.5;
    float gw = zf * px * 1.2;
    vec3 floorc = vec3(0.02, 0.01, 0.05) + purple * 0.05;
    floorc += pink * p_grid * (0.55 + 0.45 * p_punch * k) * exp(-gd / max(gw, 1e-4)) * exp(-zf * 0.08);
    floorc += pink * 0.12 * exp(-(yh - p.y) * 12.0);                   // horizon haze
    col = floorc;
    // Rows: one beat each, from the far ones (out at the horizon, the beats to come) to the beat
    // underfoot, painted back to front so near ridges hide the ones behind them.
    float near = 0.55, dz = 0.42;
    float jnow = floor(u_beat);
    float n = floor(p_rows + 0.5);
    for (int i = 47; i >= -1; i--) {
      float fi = float(i);
      if (fi >= n) continue;
      float bj = jnow + fi;                                           // this row's beat
      float z = near + (bj - u_beat) * dz;
      if (z < 0.12) continue;
      float ybase = yh - ch * f / z;
      // Each row is one beat across the screen (Row width of it), whatever its depth, so every
      // sample of the waveform shows; the grid under it keeps the perspective.
      float xn = p.x / (W * p_width) * 0.5 + 0.5;
      vec4 w = xn > 0.0 && xn < 1.0 ? sw_wave(bj + xn) : vec4(0.0);
      float edge = smoothstep(0.0, 0.04, xn) * smoothstep(1.0, 0.96, xn);
      // Ridge height is a share of the camera height, so a peak never reaches the horizon (it would
      // hide every row behind it).
      float yr = ybase + min(p_amp * (0.9 + 0.2 * arc), 1.6) * 0.55 * ch * w.x * edge * f / z;
      float lw = max(px, 0.006 / z);
      // Behind this ridge: the floor in front of it covers whatever was drawn for farther rows.
      if (p.y < yr) col = floorc;
      float fog = exp(-max(z - near, 0.0) * 0.12);
      vec3 rc = normalize(w.yzw + 0.05) ;
      vec3 ridge = pink * rc.x + purple * rc.y + cyan * rc.z;
      ridge = mix(ridge, vec3(1.0), 0.2 * smoothstep(1.0, 0.2, z));
      float onLine = clamp(1.0 - abs(p.y - yr) / lw, 0.0, 1.0);
      float now = exp(-abs(bj + 0.5 - u_beat) * 1.5);                 // the row under your feet glows
      col += ridge * (onLine * (0.8 + 0.6 * now) + p_glow * 0.35 * exp(-abs(p.y - yr) / (lw * 4.0)) * step(p.y, yr + lw * 6.0)) * fog * (0.8 + 0.4 * p_punch * k * now);
    }
  }
  return col * p_bright * (1.0 + 0.25 * arc);
}
