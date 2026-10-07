// Pyramids: one pyramid in soft clay, centred for a triangle surface (a pyramid on a pyramid), for the
// Dinki Dell doof. A sun sits behind its tip and the capstone, the eye in a golden triangle, floats
// above it. On the beat a band of light sweeps up the faces and the stone courses glint as it passes;
// the capstone comes down through a build, lands on the drop and sends a beam up to the apex.
// Simple shapes on a flat sky, nothing near the sides, so a trimmed triangle still shows it all.
// Params are p_* uniforms; ranges and defaults are in pyramids.json.
uniform float p_size, p_cy, p_sun, p_cap, p_courses, p_sweep, p_beat, p_drop, p_beam, p_pal, p_follow, p_bright;

#define PI 3.1415927

float sdTri(vec2 p, vec2 a, vec2 b, vec2 c) {   // a triangle, any winding (after Inigo Quilez)
  vec2 e0 = b - a, e1 = c - b, e2 = a - c, v0 = p - a, v1 = p - b, v2 = p - c;
  vec2 q0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
  vec2 q1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
  vec2 q2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
  float s = sign(e0.x * e2.y - e0.y * e2.x);
  vec2 d = min(min(vec2(dot(q0, q0), s * (v0.x * e0.y - v0.y * e0.x)), vec2(dot(q1, q1), s * (v1.x * e1.y - v1.y * e1.x))),
               vec2(dot(q2, q2), s * (v2.x * e2.y - v2.y * e2.x)));
  return -sqrt(d.x) * sign(d.y);
}
float sdEll(vec2 p, vec2 r) { return (length(p / r) - 1.0) * min(r.x, r.y); }
float fill(float d) { return 1.0 - smoothstep(-u_px, u_px, d); }

const vec2 LGT = vec2(-0.6, 0.8);
const float BEV = 0.014;
vec3 clay(vec3 col, vec3 base, float d, float dl) {
  float a = fill(d);
  if (a <= 0.0) return col;
  float h = clamp(-d / BEV, 0.0, 1.0);
  float lit = clamp((dl - d) / (0.5 * BEV), -1.0, 1.0) * (1.0 - h);
  vec3 c = base * (0.9 + 0.1 * h) * (1.0 + 0.28 * lit) + 0.14 * pow(max(lit, 0.0), 3.0);
  return mix(col, c, a);
}
vec3 shade(vec3 col, float ds) { return col * (1.0 - 0.22 * (1.0 - smoothstep(-0.01, 0.025, ds))); }

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0); p.y = -p.y;
  float k = kick() * p_beat, dr = dropArc() * p_drop;
  float build = clamp(u_progress, 0.0, 1.0) * step(3.5, u_scene) * step(u_scene, 5.5);
  vec2 q = (p - vec2(0.0, p_cy)) / p_size;
  float hs = p_follow > 0.5 ? u_hue - 0.1 : 0.0;

  // Palettes: 0 desert, 1 the cover (lime), 2 night, 3 pink.
  vec3 SKY = vec3(0.99, 0.8, 0.5), SKY2 = vec3(0.99, 0.62, 0.42), SAND = vec3(0.98, 0.76, 0.46), SUN = vec3(1.0, 0.92, 0.55);
  vec3 LIT = vec3(0.99, 0.82, 0.52), DARK = vec3(0.86, 0.55, 0.32), GOLD = vec3(0.98, 0.76, 0.33);
  if (p_pal > 0.5 && p_pal < 1.5) { SKY = vec3(0.882, 0.918, 0.482); SKY2 = vec3(0.82, 0.88, 0.45); SAND = vec3(0.99, 0.8, 0.6); SUN = vec3(1.0, 0.86, 0.62); LIT = vec3(0.99, 0.8, 0.62); DARK = vec3(0.62, 0.56, 0.76); }
  else if (p_pal > 1.5 && p_pal < 2.5) { SKY = vec3(0.1, 0.06, 0.22); SKY2 = vec3(0.28, 0.1, 0.4); SAND = vec3(0.22, 0.12, 0.35); SUN = vec3(1.0, 0.45, 0.75); LIT = vec3(0.4, 0.95, 0.9); DARK = vec3(0.2, 0.45, 0.75); }
  else if (p_pal > 2.5) { SKY = vec3(0.99, 0.76, 0.82); SKY2 = vec3(0.98, 0.62, 0.72); SAND = vec3(1.0, 0.85, 0.7); SUN = vec3(1.0, 0.95, 0.6); LIT = vec3(0.99, 0.88, 0.7); DARK = vec3(0.86, 0.5, 0.62); }
  if (hs != 0.0) { vec3 o = hsv(fract(hs), 0.25, 1.0); o /= max(max(o.r, o.g), o.b); SKY *= o; SKY2 *= o; }

  // The pyramid: base corners, the tip, and the front corner where its two faces meet.
  vec2 L = vec2(-0.3, -0.33), R = vec2(0.3, -0.33), A = vec2(0.0, 0.11), F = vec2(0.05, -0.36);
  float ground = -0.33;

  // ---- sky, the sun behind the tip, the beam on the drop
  vec3 col = mix(SKY2, SKY, smoothstep(ground, 0.35, q.y)) * (1.0 + 0.1 * dr);
  if (p_sun > 0.5) {
    vec2 sc = vec2(0.0, 0.06);
    float sr = 0.2 + 0.006 * k + 0.02 * dr;
    if (length(q - sc) < sr + 0.03) col = clay(col, SUN, length(q - sc) - sr, length(q - sc + LGT * 0.01) - sr);
  }
  if (p_beam > 0.5 && dr > 0.001) {
    float beam = (1.0 - smoothstep(0.0, 0.015 + 0.025 * dr, abs(q.x))) * step(A.y, q.y);
    col += vec3(1.0, 0.97, 0.85) * beam * dr * 0.9;
  }
  // ---- the sand: one flat band
  col = clay(col, SAND, q.y - ground, q.y + 0.008 - ground);

  // ---- the pyramid, two faces in soft clay, the courses as faint lines
  if (abs(q.x) < 0.38 && q.y > -0.42 && q.y < 0.16) {
    float dl = sdTri(q, A, L, F), drt = sdTri(q, A, F, R);
    float d = min(dl, drt), dlt = min(sdTri(q + LGT * 0.008, A, L, F), sdTri(q + LGT * 0.008, A, F, R));
    col = shade(col, min(sdTri(q - vec2(0.035, 0.0), A, L, F), sdTri(q - vec2(0.035, 0.0), A, F, R)));
    float t = clamp((q.y - L.y) / (A.y - L.y), 0.0, 1.0);
    float course = (1.0 - smoothstep(0.0, 0.16, abs(fract(t * 12.0) - 0.5) * 2.0 - 0.82));
    vec3 base = (dl < drt ? LIT : DARK) * (1.0 - 0.08 * p_courses * course);
    col = clay(col, base, d, dlt);
    // The sweep: a band of light rising up the faces over each beat, the courses glinting in it.
    float band = exp(-abs(t - u_frac * 1.25) * 9.0) * (1.0 - u_frac) * p_sweep * (0.6 + 0.4 * k);
    col += vec3(1.0, 0.95, 0.8) * fill(d) * band * (0.25 + 0.75 * course * p_courses) * 0.6;
  }

  // ---- the capstone: the eye in a golden triangle, floating above the tip; down through a build, landed on the drop
  if (p_cap > 0.5) {
    float gap = 0.075 * (1.0 - build) * (1.0 - dr) + 0.01 * sin(u_beat * PI * 0.5) * (1.0 - dr);
    vec2 cq = (q - vec2(0.0, A.y - 0.087 + gap * 1.2)) / 1.5;              // drawn at 1.5x: it has to read on a pyramid face
    if (abs(cq.x) < 0.12 && cq.y > -0.04 && cq.y < 0.12) {
      vec2 a = vec2(0.0, 0.07), l = vec2(-0.07, 0.0), r = vec2(0.07, 0.0);
      float cd = sdTri(cq, a, l, r) * 1.5;
      col = shade(col, sdTri(cq - vec2(0.012, -0.01), a, l, r) * 1.5);
      col = clay(col, GOLD * (1.0 + 0.25 * k + 0.4 * dr), cd, sdTri(cq + LGT * 0.004, a, l, r) * 1.5);
      vec2 e = (cq - vec2(0.0, 0.024)) / 0.028;
      float blink = smoothstep(0.93, 1.0, fract(u_beat / 16.0)) * (1.0 - smoothstep(0.98, 1.0, fract(u_beat / 16.0)));
      float wd = sdEll(e, vec2(1.0, max(0.02, 0.55 * (1.0 - 2.0 * blink) + 0.2 * dr))) * 0.042;
      col = mix(col, vec3(0.99, 0.97, 0.93), fill(wd));
      if (wd < 0.0) {
        vec2 look = 0.25 * vec2(sin(u_beat * 0.37), 0.3 * sin(u_beat * 0.23)) * (1.0 - dr);
        col = mix(col, vec3(0.3, 0.68, 0.88), fill((length(e - look) - 0.42) * 0.042));
        col = mix(col, vec3(0.08, 0.1, 0.14), fill((length(e - look) - 0.2) * 0.042));
      }
    }
  }
  return clamp(col * p_bright, 0.0, 1.0);
}
