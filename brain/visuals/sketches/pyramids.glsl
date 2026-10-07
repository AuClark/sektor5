// Pyramids: the three of Giza in soft clay under a big sun, for the Dinki Dell doof. The sun's fat rays
// turn behind them, the dunes roll, the Nile runs along the front as the cover's blue tube. On the beat
// a light climbs each pyramid's edges in turn (left, middle, right) and the stone courses glint. Above
// the great pyramid its capstone floats, the eye in a golden triangle: it comes down through a build,
// lands on the drop, and a beam of light goes up into the sky.
// Each object only works out its detail on the pixels near it, so most of the screen is a flat colour.
// Params are p_* uniforms; ranges and defaults are in pyramids.json.
uniform float p_size, p_cy, p_sun, p_rays, p_spin, p_nile, p_cap, p_beam, p_courses, p_chase,
              p_beat, p_drop, p_pal, p_follow, p_bright;

#define TAU 6.2831853
#define PI 3.1415927

float sdSeg(vec2 p, vec2 a, vec2 b) { vec2 pa = p - a, ba = b - a; return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0)); }
float sdEll(vec2 p, vec2 r) { return (length(p / r) - 1.0) * min(r.x, r.y); }
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
mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }

// Clay: a shape shaded by how its rim faces the light (top left), flat in the middle.
const vec2 LGT = vec2(-0.6, 0.8);
const float BEV = 0.014;
vec3 clay(vec3 col, vec3 base, float d, float dl) {
  float a = (1.0 - smoothstep(-u_px, u_px, d));
  if (a <= 0.0) return col;
  float h = clamp(-d / BEV, 0.0, 1.0);
  float lit = clamp((dl - d) / (0.5 * BEV), -1.0, 1.0) * (1.0 - h);
  vec3 c = base * (0.9 + 0.1 * h) * (1.0 + 0.28 * lit);
  c += 0.14 * pow(max(lit, 0.0), 3.0);
  return mix(col, c, a);
}
vec3 shade(vec3 col, float ds, float amt) { return col * (1.0 - amt * (1.0 - smoothstep(-0.01, 0.025, ds))); }

// A pyramid seen a little from the side: base from x-w to x+w at y, apex above, the near corner
// (where its two faces meet) a touch forward. Returns the outline's distance; face = 0 left, 1 right.
float pyr(vec2 p, vec2 b, float w, float h, out float face) {
  vec2 A = b + vec2(0.06 * w, h), L = b - vec2(w, 0.0), R = b + vec2(w, 0.0), F = b + vec2(0.3 * w, -0.06 * h);
  float dl = sdTri(p, A, L, F), dr = sdTri(p, A, F, R);
  face = dl < dr ? 0.0 : 1.0;
  return min(dl, dr);
}

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0); p.y = -p.y;
  float k = kick() * p_beat, dr = dropArc() * p_drop;
  float fit = min(1.0, u_aspect / 1.6) * p_size;
  vec2 q = (p - vec2(0.0, p_cy)) / fit;
  float hs = p_follow > 0.5 ? u_hue - 0.1 : 0.0;

  // Palettes: 0 desert, 1 the cover (lime sky), 2 night, 3 pink.
  vec3 SKY = vec3(0.99, 0.84, 0.55), SKY2 = vec3(0.99, 0.66, 0.45), SAND = vec3(0.98, 0.78, 0.48), SUN = vec3(1.0, 0.9, 0.5);
  vec3 LIT = vec3(0.99, 0.8, 0.5), DARK = vec3(0.86, 0.55, 0.32), NILE = vec3(0.0, 0.62, 0.84), GOLD = vec3(0.98, 0.76, 0.33);
  if (p_pal > 0.5 && p_pal < 1.5) { SKY = vec3(0.882, 0.918, 0.482); SKY2 = vec3(0.8, 0.88, 0.45); SAND = vec3(0.99, 0.8, 0.6); SUN = vec3(1.0, 0.86, 0.62); LIT = vec3(0.99, 0.8, 0.62); DARK = vec3(0.62, 0.56, 0.76); }
  else if (p_pal > 1.5 && p_pal < 2.5) { SKY = vec3(0.1, 0.06, 0.22); SKY2 = vec3(0.3, 0.1, 0.4); SAND = vec3(0.22, 0.12, 0.35); SUN = vec3(1.0, 0.45, 0.75); LIT = vec3(0.4, 0.95, 0.9); DARK = vec3(0.2, 0.45, 0.75); NILE = vec3(1.0, 0.4, 0.75); }
  else if (p_pal > 2.5) { SKY = vec3(0.99, 0.75, 0.8); SKY2 = vec3(0.98, 0.6, 0.72); SAND = vec3(1.0, 0.85, 0.7); SUN = vec3(1.0, 0.95, 0.6); LIT = vec3(0.99, 0.88, 0.7); DARK = vec3(0.86, 0.5, 0.62); }
  if (hs != 0.0) { vec3 o = hsv(fract(hs), 0.25, 1.0); SKY *= o / max(max(o.r, o.g), o.b); SKY2 *= o / max(max(o.r, o.g), o.b); }

  // ---- sky: a soft band of colour toward the horizon, brighter on the drop
  float horizon = -0.18;
  vec3 col = mix(SKY2, SKY, smoothstep(horizon, 0.45, q.y)) * (1.0 + 0.1 * dr);

  // ---- the sun and its rays, behind the great pyramid
  vec2 sc = vec2(0.42, 0.2);
  vec2 s = q - sc;
  if (p_sun > 0.5 && dot(s, s) < 0.36) {
    float n = floor(p_rays + 0.5), a = atan(s.y, s.x) - u_beat * p_spin * TAU / 64.0, sec = TAU / n;
    float i = floor(a / sec + 0.5);
    vec2 r = rot(-(i * sec + u_beat * p_spin * TAU / 64.0)) * s;
    float len = 0.27 + 0.03 * sin(i * 2.4) + 0.03 * k + 0.12 * dr;
    float rd = sdSeg(r, vec2(0.16, 0.0), vec2(len, 0.0)) - 0.016;
    col = clay(col, mix(SUN, SKY, 0.25), rd, rd + 0.004 * dot(normalize(s), LGT));
    float sd = length(s) - (0.13 + 0.008 * k + 0.02 * dr);
    col = clay(col, SUN, sd, length(s + LGT * 0.01) - (0.13 + 0.008 * k + 0.02 * dr));
  }

  // ---- the capstone's beam on the drop, up from the great pyramid into the sky
  vec2 apex = vec2(-0.02 + 0.06 * 0.32, -0.16 + 0.46);
  if (p_beam > 0.5 && dr > 0.001) {
    float bw = 0.02 + 0.03 * dr;
    float beam = (1.0 - smoothstep(0.0, bw, abs(q.x - apex.x))) * step(apex.y, q.y);
    col += vec3(1.0, 0.97, 0.85) * beam * dr * 0.9;
  }

  // ---- ground: sand with two rolling dunes
  float dune = horizon + 0.03 * sin(q.x * 4.0 + 0.6) + 0.02 * sin(q.x * 9.0);
  float gd = q.y - dune;
  col = clay(col, SAND, gd, q.y + LGT.y * 0.01 - dune);
  float dune2 = horizon - 0.16 + 0.04 * sin(q.x * 3.0 + 2.0);
  col = clay(col, SAND * 1.04, q.y - dune2, q.y + LGT.y * 0.01 - dune2);

  // ---- the three pyramids: left small, great in the middle, right medium. On the beat a light climbs
  //      each one's edges in turn (beats 1, 2, 3 of the bar), and the courses glint as it passes.
  float bb = barBeat(), inBar = bb - 4.0 * floor(bb / 4.0);
  vec2 B[3]; float W[3], H[3];
  B[0] = vec2(-0.48, -0.17); W[0] = 0.2;  H[0] = 0.26;
  B[1] = vec2(-0.02, -0.16); W[1] = 0.32; H[1] = 0.46;
  B[2] = vec2(0.4, -0.17);   W[2] = 0.24; H[2] = 0.32;
  for (int i = 0; i < 3; i++) {
    vec2 bi = B[i]; float wi = W[i], hi = H[i] * (1.0 + 0.02 * k * float(i == 1));
    if (abs(q.x - bi.x) > wi + 0.08 || q.y < bi.y - 0.08 || q.y > bi.y + hi + 0.08) continue;
    float face, fl;
    float d = pyr(q, bi, wi, hi, face), dl = pyr(q + LGT * 0.008, bi, wi, hi, fl);
    col = shade(col, pyr(q - vec2(0.03, 0.012), bi, wi, hi, fl), 0.22);
    vec3 base = face < 0.5 ? LIT : DARK;
    float t = clamp((q.y - bi.y) / hi, 0.0, 1.0);
    // Courses: faint horizontal lines of stone, a step every so often up the face.
    float crs = p_courses * (1.0 - smoothstep(0.0, 0.18, abs(fract(t * 14.0) - 0.5) * 2.0 - 0.82)) * 0.08;
    base *= 1.0 - crs;
    col = clay(col, base, d, dl);
    // The chase: this pyramid's beat, a light rising up its outline over the beat.
    float ph = inBar - float(i);
    if (p_chase > 0.0 && ph >= 0.0 && ph < 1.0 && d < 0.02) {
      float climb = ph * 1.3;
      float edge = exp(-abs(d) / 0.004) * (1.0 - smoothstep(climb - 0.25, climb, t)) * (1.0 - ph);
      col += vec3(1.0, 0.95, 0.8) * edge * p_chase;
      col += vec3(1.0, 0.9, 0.7) * crs * 6.0 * (1.0 - smoothstep(climb - 0.1, climb, t)) * step(climb - 0.3, t) * step(d, 0.0) * (1.0 - ph) * p_chase;
    }
  }

  // ---- the capstone: the eye in a golden triangle, floating over the great pyramid; it comes down
  //      through a build and lands on the drop
  if (p_cap > 0.5) {
    float gap = 0.09 * (1.0 - clamp(u_progress, 0.0, 1.0) * step(3.5, u_scene) * step(u_scene, 5.5)) * (1.0 - dr) + 0.012 * sin(u_beat * PI * 0.5);
    vec2 cb = apex + vec2(0.0, gap - 0.07);
    float cw = 0.075, ch = 0.075;
    vec2 cq = q - cb;
    if (abs(cq.x) < 0.15 && cq.y > -0.06 && cq.y < 0.15) {
      vec2 A = vec2(0.0, ch), L = vec2(-cw, 0.0), R = vec2(cw, 0.0);
      float cd = sdTri(cq, A, L, R);
      col = shade(col, sdTri(cq - vec2(0.015, -0.012), A, L, R), 0.2);
      col = clay(col, GOLD * (1.0 + 0.25 * k + 0.4 * dr), cd, sdTri(cq + LGT * 0.006, A, L, R));
      vec2 e = (cq - vec2(0.0, 0.026)) / 0.03;
      float blink = smoothstep(0.93, 1.0, fract(u_beat / 16.0)) * (1.0 - smoothstep(0.98, 1.0, fract(u_beat / 16.0)));
      float wd = sdEll(e, vec2(1.0, max(0.02, 0.55 * (1.0 - 2.0 * blink) + 0.2 * dr))) * 0.03;
      col = mix(col, vec3(0.99, 0.97, 0.93), (1.0 - smoothstep(-u_px, u_px, wd)));
      if (wd < 0.0) {
        vec2 look = 0.25 * vec2(sin(u_beat * 0.37), 0.3 * sin(u_beat * 0.23)) * (1.0 - dr);
        col = mix(col, vec3(0.3, 0.68, 0.88), (1.0 - smoothstep(-u_px, u_px, (length(e - look) - 0.42) * 0.03)));
        col = mix(col, vec3(0.08, 0.1, 0.14), (1.0 - smoothstep(-u_px, u_px, (length(e - look) - 0.2) * 0.03)));
      }
    }
  }

  // ---- the Nile: the cover's blue tube, running along the front
  if (p_nile > 0.5) {
    float ny = horizon - 0.25 + 0.035 * sin(q.x * 5.0 + u_beat * 0.25) + 0.01 * k * sin(q.x * 20.0);
    float nd = abs(q.y - ny), R = 0.022;
    col = shade(col, abs(q.y + 0.018 - ny) - R, 0.2);
    float a = (1.0 - smoothstep(-u_px, u_px, nd - R));
    if (a > 0.0) {
      float n = clamp(nd / R, 0.0, 1.0), side = sign(q.y - ny);
      vec3 c = NILE * (0.62 + 0.38 * sqrt(1.0 - n * n)) * (1.0 + 0.2 * side * n);
      c += 0.35 * pow(max(side * n, 0.0), 4.0) * (1.0 - n * 0.5);
      col = mix(col, c, a);
    }
  }
  return clamp(col * p_bright, 0.0, 1.0);
}
