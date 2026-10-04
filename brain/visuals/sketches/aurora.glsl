// Aurora: the northern lights over a mountain lake. Layered curtains hang in the sky, each a
// ribbon that folds and drifts, bright and sharp along its lower edge and fading upwards through
// green into violet and pink, streaked with vertical rays. The lake below mirrors them through
// ripples, under a line of pines and two ridges of mountains.
// It follows the music: the synths (the waveform's mids) swell the curtains and set them
// moving, the highs make the rays shimmer, the kick sends a pulse of light along each curtain,
// and the build into a drop (dropArc) brightens them into a pink-topped burst.
// Nothing goes yellow (au_hue skips amber..chartreuse, as the lights do).
// Params are p_* uniforms; ranges and defaults are in aurora.json.
uniform float p_curtains, p_bright, p_height, p_fold, p_drift, p_rays, p_shimmer, p_glow,
              p_lake, p_ripple, p_stars, p_trees, p_green, p_top, p_hue, p_follow, p_react, p_punch;

#define TAU 6.28318531

float au_h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float au_n(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(au_h(i), au_h(i + vec2(1.0, 0.0)), f.x), mix(au_h(i + vec2(0.0, 1.0)), au_h(i + vec2(1.0, 1.0)), f.x), f.y);
}
float au_fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { v += a * au_n(p); p = p * 2.03 + vec2(1.7, 9.2); a *= 0.5; } return v; }
float au_hue(float h) {
  h = fract(h);
  if (h > 0.03 && h < 0.36) { float o = 0.03 + (h - 0.03) / 0.33 * 0.175; return o >= 0.095 ? o + 0.155 : o; }
  return h;
}
vec3 au_col(float h, float s, float v) { return hsv(au_hue(h), s, v); }

// The curtains at a point of the sky (q.y above the horizon), t in beats.
vec3 aurora(vec2 q, float t, float M, float Hi, float H, float arc) {
  vec3 col = vec3(0.0);
  float n = floor(p_curtains + 0.5);
  float k = kick();
  for (int i = 0; i < 5; i++) {
    float fi = float(i);
    if (fi >= n) break;
    float sp = (0.5 + 0.3 * fi) * p_drift * (0.6 + 0.8 * p_react * M);
    // The ribbon: its lower edge wanders and folds back on itself.
    float x = q.x * (0.8 + 0.25 * fi) + fi * 3.7;
    x += p_fold * 0.35 * sin(x * 1.7 + t * 0.12 * sp + fi);
    // Each curtain sweeps across the sky in a long S, the far ones higher up.
    float base = 0.1 + 0.09 * fi + 0.12 * sin(x * (0.9 + 0.2 * fi) + fi * 2.1 + t * 0.02 * sp)
               + 0.3 * (au_fbm(vec2(x * 0.5 + t * 0.03 * sp, fi * 5.0)) - 0.5);
    float d = q.y - base;
    if (d < -0.02) continue;
    float hgt = p_height * (0.07 + 0.14 * au_n(vec2(x * 0.7, fi))) * (0.8 + 0.5 * M * p_react + 0.4 * arc);
    // A curtain comes in stretches with gaps between, which drift along it.
    float pres = smoothstep(0.38, 0.62, au_n(vec2(x * 0.4 + t * 0.012 * sp, fi * 11.0)));
    if (pres <= 0.0) continue;
    float body = exp(-max(d, 0.0) / hgt) * smoothstep(-0.02, 0.012, d);
    float edge = exp(-abs(d) / 0.012);                              // the bright lower hem
    // Rays: vertical streaks that drift along the curtain and flicker with the highs.
    float r = au_n(vec2(x * 38.0 + t * 0.4 * sp, fi * 7.0 + floor(t * 4.0) * (0.3 * p_shimmer * Hi)));
    float rays = mix(1.0, 0.35 + 1.3 * r * r, p_rays);
    // A pulse of light runs along each curtain on the kick.
    float pd = fract(x * 0.15 - t * 0.25) - 0.5;                     // (pow() of a negative is undefined in GLSL)
    float pulse = 1.0 + p_punch * 1.2 * k * exp(-pd * pd * 30.0);
    float lvl = (body * rays + 0.7 * edge) * pulse * pres * (0.9 - 0.12 * fi);
    float up = clamp(d / (hgt * 2.2), 0.0, 1.0);
    vec3 c = mix(au_col(p_green + H, 0.85, 1.0), au_col(p_top + H + 0.05 * fi, 0.7, 1.0), smoothstep(0.15, 0.9, up + 0.25 * arc));
    col += c * lvl;
  }
  return col * p_glow;
}

vec3 content(vec2 uv) {
  float W = u_aspect * 0.5;
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
  p.y = -p.y;
  float px = u_px, t = u_beat;
  float M = u_wv.w > 0.0 ? wave(u_beat).z : 0.5, Hi = u_wv.w > 0.0 ? wave(u_beat).w : 0.5;
  float H = p_hue + (p_follow > 0.5 ? u_hue - p_green : 0.0);
  float arc = dropArc();
  float shore = -0.16;

  // Below the shore line we're looking at the lake: mirror the sky through ripples.
  bool lake = p.y < shore;
  vec2 q = p;
  if (lake) {
    float dd = shore - p.y;
    q.y = shore + dd;
    q.x += p_ripple * 0.012 * sin(dd * 140.0 / (0.3 + dd) - t * 1.5) * (0.4 + dd * 3.0);
  }
  vec2 s = vec2(q.x, q.y - shore);                                // height above the shore

  // Sky: deep navy, a little teal glow low down, stars.
  vec3 col = mix(au_col(0.55 + H * 0.3, 0.7, 0.1), vec3(0.005, 0.01, 0.04), smoothstep(0.0, 0.7, s.y));
  vec2 sg = floor(q * 80.0), sf = fract(q * 80.0) - 0.5 - (vec2(au_h(sg + 2.0), au_h(sg + 5.0)) - 0.5) * 0.6;
  col += p_stars * step(0.9, au_h(sg)) * smoothstep(0.1, 0.0, length(sf)) * (0.5 + 0.5 * sin(t * 1.5 + au_h(sg + 1.0) * 40.0)) * 0.8;
  vec3 au = aurora(s, t, M, Hi, H, arc);
  col += vec3(1.0) - exp(-au * 1.3);                                 // overlapping curtains glow rather than clip to white

  // Mountains, two ridges, the near one darker; then the pines along the shore.
  float far = 0.06 + 0.2 * au_fbm(vec2(q.x * 1.4, 2.0)) + 0.05 * sin(q.x * 2.3);
  // Far mountains, lit faintly by the aurora, with snow on the tops.
  vec3 rock = au_col(0.62 + H * 0.3, 0.5, 0.07) + aurora(vec2(s.x, far + 0.05), t, M, Hi, H, arc) * 0.08;
  rock += vec3(0.25, 0.3, 0.4) * smoothstep(far - 0.03, far, s.y) * smoothstep(0.14, 0.2, far) * 0.6;
  col = mix(col, rock, clamp(0.5 - (s.y - far) / px, 0.0, 1.0));
  float nearR = 0.03 + 0.08 * au_fbm(vec2(q.x * 2.0 + 7.0, 4.0));
  col = mix(col, vec3(0.008, 0.012, 0.03), clamp(0.5 - (s.y - nearR) / px, 0.0, 1.0));
  if (p_trees > 0.0) {
    // Pines: tiered spires of different heights.
    float cw = 0.03, cx = floor(q.x / cw);
    float th = p_trees * (0.05 + 0.09 * au_h(vec2(cx, 3.0)));
    float lx = abs(fract(q.x / cw) - 0.5) * cw;
    float yy = s.y / max(th, 1e-3);
    float tier = fract(yy * 4.0);
    float halfw = cw * 0.5 * (1.0 - yy) * (0.55 + 0.45 * (1.0 - tier));
    float tree = max(lx - halfw, s.y - th);
    tree = min(tree, max(lx - cw * 0.06, s.y - th * 0.2));           // the trunk
    col = mix(col, vec3(0.0, 0.004, 0.012), clamp(0.5 - tree / px, 0.0, 1.0) * step(0.0, s.y + 0.01) * step(yy, 1.0));
  }

  if (lake) {
    float dd = shore - p.y;
    col *= p_lake * (0.8 - 0.35 * smoothstep(0.0, 0.35, dd));
    col += au_col(0.58 + H * 0.3, 0.6, 0.03);                      // the water's own dark teal
    col += vec3(0.6, 0.8, 1.0) * 0.08 * exp(-dd * 60.0);           // the shore line catching the light
  }
  return col * p_bright * (1.0 + 0.3 * arc);
}
