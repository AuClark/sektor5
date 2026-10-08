// Throne: a golden sacred-geometry mandala — rings, petals, spokes, hexagons and
// triangles in counter-rotating layers, golden-ratio spiral arms and fractal hex lace
// (after "Golden Throne" in Paul Bakaus's Radiant collection, MIT). Ported nearly line
// for line; changes: reversed smoothsteps (undefined in GLSL) written as 1 - smoothstep,
// a local named `dot` renamed (it hid the built-in), the spokes' dark-ray bug fixed, unused functions dropped, time in
// beats, the centre and inner ring pulse on the kick instead of a clock, and a size
// control so it fits any surface. Params are p_* uniforms; ranges and defaults are in throne.json.
uniform float p_fill, p_size, p_speed, p_rot, p_layers, p_spin, p_spiral, p_lace, p_punch, p_glow,
              p_tint, p_hue, p_sat, p_bright, p_follow;

#define PI 3.14159265359
#define TAU 6.28318530718
#define PHI 1.6180339887

mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

// The original's cosine gold palette, or a tint of it.
vec3 gold(float t) {
  vec3 g = vec3(0.45, 0.32, 0.14) + vec3(0.45, 0.35, 0.2) * cos(TAU * (vec3(1.0, 0.8, 0.5) * t + vec3(0.0, 0.1, 0.25)));
  float lum = dot(max(g, 0.0), vec3(0.299, 0.587, 0.114));
  vec3 tinted = hsv(mix(p_hue, u_hue, p_follow) + 0.05 * sin(TAU * t), p_sat, lum * 1.2);
  return mix(g, tinted, p_tint);
}
vec3 warm(vec3 c) {             // the original's fixed white-golds, tinted the same way
  float lum = dot(c, vec3(0.299, 0.587, 0.114));
  return mix(c, hsv(mix(p_hue, u_hue, p_follow), p_sat * 0.5, lum * 1.1), p_tint);
}

float hexDist(vec2 p) {
  p = abs(p);
  return max(p.x + p.y * 0.577350269, p.y * 1.154700538);
}
float triDist(vec2 p) {
  float k = sqrt(3.0);
  p.x = abs(p.x) - 1.0;
  p.y = p.y + 1.0 / k;
  if (p.x + k * p.y > 0.0) p = vec2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
  p.x -= clamp(p.x, -2.0, 0.0);
  return -length(p) * sign(p.y);
}

float mandalaLayer(vec2 uv, float time, float layer, float totalLayers) {
  float t = layer / totalLayers;
  float radius = 0.08 + t * 0.38;
  // Differential rotation: inner faster, outer slower, alternate layers counter-rotating.
  float speed = p_rot * (1.5 - t * 1.2);
  float direction = mod(layer, 2.0) < 1.0 ? 1.0 : -1.0;
  vec2 p = rot(time * speed * direction + layer * PHI) * uv;

  float d = 1e9;
  float symmetry = 6.0 + floor(layer * 1.5);
  float angle = atan(p.y, p.x);
  float r = length(p);
  float sector = TAU / symmetry;
  float a = mod(angle + sector * 0.5, sector) - sector * 0.5;
  vec2 sp = vec2(cos(a), sin(a)) * r;

  d = min(d, abs(r - radius) - 0.003 * (1.0 + t));                                   // ring
  d = min(d, abs(length(sp - vec2(radius, 0.0)) - radius * 0.35 / PHI) - 0.002);      // petal arcs
  d = min(d, abs(length(sp - vec2(radius * 0.65, 0.0)) - radius * 0.25) - 0.0015);    // inner petals
  float spokeMask = smoothstep(radius - 0.05, radius - 0.01, r) * (1.0 - smoothstep(radius + 0.01, radius + 0.05, r));
  // Spokes. The original divided by the mask, which on the spoke line away from the ring
  // gives a large negative distance that wins the min and draws dark rays; push it away instead.
  d = min(d, abs(sp.y) - 0.001 + (1.0 - spokeMask) * 0.1);
  d = min(d, hexDist(sp - vec2(radius, 0.0)) - (0.012 + t * 0.008));                   // hexagons
  if (layer > 1.0) d = min(d, triDist((sp - vec2(radius * 0.5, 0.0)) * 60.0) / 60.0);  // triangles
  return d;
}

float goldenSpiral(vec2 uv, float time) {
  float r = length(uv);
  float a = atan(uv.y, uv.x);
  float spiralPhase = log(max(r, 0.001)) / log(PHI) * PI * 0.5;
  float spiralD = abs(mod(a - spiralPhase + time * p_rot * 0.2 + PI, TAU) - PI);
  spiralD = min(spiralD, abs(mod(a - spiralPhase + time * p_rot * 0.2 + PI + PI, TAU) - PI));
  float fade = smoothstep(0.0, 0.05, r) * (1.0 - smoothstep(0.35, 0.5, r));
  return spiralD * fade + (1.0 - fade);
}

float fractalDetail(vec2 uv, float time) {
  float scale = 1.0, intensity = 0.0;
  for (int i = 0; i < 4; i++) {
    float fi = float(i);
    vec2 p = rot(time * p_rot * (0.1 + fi * 0.05) * (mod(fi, 2.0) < 1.0 ? 1.0 : -1.0)) * (uv * scale);
    float hexSize = 0.15 / scale;
    float hx = hexDist(mod(p + hexSize, hexSize * 2.0) - hexSize);
    float hexLine = abs(hx - hexSize * 0.4) - 0.001 * scale;
    intensity += (1.0 - smoothstep(0.0, 0.003, hexLine)) * (0.15 / (1.0 + fi));
    scale *= PHI;
  }
  return intensity;
}

vec3 content(vec2 uv0) {
  // The original's coordinates: centred, shorter side = 1, y up; Size scales the mandala.
  // Fill the screen: zoomed so the mandala's outer ring reaches the surface's corners (Size 1), whatever its shape.
  float cover = p_fill > 0.5 ? 0.5 * sqrt(u_aspect * u_aspect + 1.0) / min(u_aspect, 1.0) / 0.48 : 1.0;
  vec2 uv = (uv0 - 0.5) * vec2(u_aspect, 1.0) / min(u_aspect, 1.0) / max(p_size * cover, 0.05);
  uv.y = -uv.y;
  float t = u_beat * p_speed;
  float k = kick();
  uv = rot(u_beat * p_spin * TAU / 64.0) * uv;
  float complexity = p_layers;
  float r = length(uv);
  float objectRadius = 0.48;
  // Fill the screen: no fade at the mandala's edge, so its layers carry on out to the surface's edges.
  float objectFade = p_fill > 0.5 ? 1.0 : 1.0 - smoothstep(objectRadius * 0.7, objectRadius, r);
  float glowk = p_glow * (1.0 + p_punch * k);

  vec3 col = vec3(0.0);
  for (int i = 0; i < 8; i++) {
    if (float(i) >= complexity) break;
    float fi = float(i);
    float ad = abs(mandalaLayer(uv, t, fi, complexity));
    float layerIntensity = 0.0025 / (ad + 0.0025) + 0.008 / (ad + 0.008) * 0.3;
    col += gold(fi / complexity + t * 0.02) * layerIntensity * (1.0 - fi / complexity * 0.5) * 0.6 * glowk;
  }

  col += gold(0.7 + t * 0.01) * (0.015 / (goldenSpiral(uv, t) + 0.015)) * 0.25 * p_spiral;
  col += gold(0.3 + t * 0.03) * fractalDetail(uv, t) * 0.4 * p_lace;

  // Centre point and inner ring: they pulse on the kick (the original used a clock).
  float centerPulse = 0.8 + 0.2 * sin(t * 1.5) + p_punch * 0.8 * k;
  col += warm(vec3(1.0, 0.92, 0.7)) * (0.01 / (r * r + 0.01)) * centerPulse * 0.08;
  float ringPulse = 0.9 + 0.1 * sin(t * 2.3 + 1.0) + p_punch * 0.4 * k;
  float innerRing = abs(r - 0.03 * ringPulse) - 0.002;
  col += warm(vec3(1.0, 0.88, 0.6)) * (0.003 / (abs(innerRing) + 0.003)) * 0.3 * glowk;

  // Ornate outer edge: two rings and twelve dots.
  float outerRing = abs(r - objectRadius + 0.01) - 0.003;
  col += gold(0.5 + t * 0.015) * (0.004 / (abs(outerRing) + 0.004)) * 0.35 * glowk;
  float outerRing2 = abs(r - objectRadius + 0.035) - 0.002;
  col += gold(0.6) * (0.003 / (abs(outerRing2) + 0.003)) * 0.2 * glowk;
  float dotA = mod(atan(uv.y, uv.x) + PI / 12.0, TAU / 12.0) - PI / 12.0;
  float dotd = length(vec2(cos(dotA), sin(dotA)) * r - vec2(objectRadius - 0.01, 0.0)) - 0.008;
  col += warm(vec3(1.0, 0.9, 0.65)) * (0.004 / (abs(dotd) + 0.004)) * 0.3 * glowk;

  col *= objectFade;
  col += warm(vec3(0.3, 0.2, 0.08)) * exp(-r * r * 6.0) * 0.06;
  col = max(col * p_bright * 1.6, vec3(0.0));   // brighter than the original: the projector crushes its dim gold lines
  col = col / (1.0 + col * 0.4);
  col = pow(col, vec3(0.95, 0.98, 1.05));
  return clamp(col, 0.0, 1.0);
}
