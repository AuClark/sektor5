// Emergence: a Turing-pattern labyrinth (after Maxime Causeret's "Order From Chaos"
// for Max Cooper). Not a real reaction-diffusion sim: a sum of plane waves of one
// wavelength in scattered directions, thresholded at a level, gives the same maze of
// worms and spirals with no feedback buffer. Each wave drifts at its own speed, so the
// maze slithers and rewires. Coloured zones, ragged rim and a hole, beat-locked.
// Params are p_* uniforms; ranges and defaults are in emergence.json.
uniform float p_waves, p_scale, p_thick, p_flow, p_turn, p_spin, p_beat,
              p_size, p_hole, p_ragged, p_grow, p_mix, p_blobs, p_hue, p_sat, p_follow, p_fill;

#define TAU 6.2831853
#define PI 3.1415927

float vnoise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

vec3 content(vec2 uv) {
  float t = u_beat;
  float k = kick() * p_beat;
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
  float sa = t * p_spin * TAU / 64.0;
  p = mat2(cos(sa), -sin(sa), sin(sa), cos(sa)) * p;

  // Labyrinth: f = sum of cosines, g = its gradient (for a pixel-exact edge).
  float kk = TAU * p_scale;
  float f = 0.0;
  vec2 g = vec2(0.0);
  for (int i = 0; i < 16; i++) {
    float fi = float(i);
    if (fi >= p_waves) break;
    float ang = fi * PI / p_waves + (hash(vec2(fi, 1.7)) - 0.5) * 0.6 + t * p_turn * TAU / 64.0;
    vec2 d = vec2(cos(ang), sin(ang));
    float ph = hash(vec2(fi, 4.3)) * TAU + t * p_flow * TAU * (hash(vec2(fi, 9.1)) * 2.0 - 1.0);
    float s = dot(p, d) * kk + ph;
    f += cos(s);
    g -= sin(s) * d * kk;
  }
  float norm = inversesqrt(max(p_waves, 1.0) * 0.5);
  f *= norm; g *= norm;
  float level = (0.5 - p_thick) * 1.6 - 0.35 * k;          // beat fattens the worms
  float d = (f - level) / max(length(g), 1e-3);            // signed distance to the edge
  float worm = smoothstep(-u_px, u_px, d);

  // Solid blobs: patches where the worms fuse into a filled shape.
  // Two rotated octaves so the value noise's square grid doesn't show.
  vec2 pb = mat2(0.8, -0.6, 0.6, 0.8) * p;
  float bn = 0.65 * vnoise(pb * 16.0 + 17.0) + 0.35 * vnoise(p * 31.0 + 5.0);
  float b0 = 0.9 - 0.25 * p_blobs;
  float blob = p_blobs > 0.0 ? smoothstep(b0, b0 + 0.03, bn) : 0.0;
  worm = max(worm, blob);

  // Organism: ragged outer rim, optional hole; grows through the song section.
  float r = length(p);
  float rr = r + p_ragged * ((vnoise(p * 4.0 + 3.0) - 0.5) * 0.16 + (vnoise(p * 15.0) - 0.5) * 0.035);
  float R = p_size * (1.0 + p_grow * (u_sp - 0.5)) * (1.0 + 0.04 * k);
  // Fill the screen: the rim goes out past the surface's corners (whatever its shape), so the maze
  // covers it all and the zones become rings across the whole picture.
  if (p_fill > 0.5) R = 0.5 * sqrt(u_aspect * u_aspect + 1.0) * (1.06 + 0.04 * k) + 0.12 * p_ragged;
  float inside = smoothstep(-u_px, u_px, R - rr);
  if (p_hole > 0.0) inside *= smoothstep(-u_px, u_px, rr - p_hole);

  // Zones: inner blue, a mixed band of pink / green / pale blue, outer teal.
  float z = (rr - p_hole) / max(R - p_hole, 1e-3) + (vnoise(p * 6.0 + 40.0) - 0.5) * p_mix;
  float pick = vnoise(mat2(0.6, 0.8, -0.8, 0.6) * p * 11.0 + 80.0);
  vec3 hs = z < 0.45 ? vec3(0.56, 0.62, 0.80)
          : z < 0.72 ? (pick < 0.4 ? vec3(0.92, 0.72, 0.86) : pick < 0.62 ? vec3(0.30, 0.58, 0.45) : vec3(0.60, 0.22, 0.88))
          :            vec3(0.48, 0.62, 0.84);
  float hue0 = p_hue + (p_follow > 0.5 ? u_hue - 0.56 : 0.0);
  vec3 col = hsv(hs.x + hue0, hs.y * p_sat, hs.z * (blob > 0.5 ? 1.08 : 1.0));
  return col * worm * inside * (0.88 + 0.12 * k);
}
