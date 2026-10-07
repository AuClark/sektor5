// Doof: the Dinki Dell doof holding screen, after the event's cover. DINKI arched, DELL and doof in
// lilac, then the eye in its sunburst, the bee and the golden disc of glyphs, with the blue tube
// wandering through, all soft clay on a lime ground. Made of a handful of simple shapes: each object
// only works out its detail on the pixels near it, so most of the screen costs a flat colour.
// On the beat: the letters hop in turn, the rays pulse, the bee flaps, the eye looks and blinks.
// On the drop: everything swells and the rays burst.
// Params are p_* uniforms; ranges and defaults are in doof.json.
uniform float p_show, p_size, p_cy, p_icons, p_text, p_tube, p_bob, p_beat, p_drop, p_hop, p_spin,
              p_bg, p_ink, p_follow, p_bright;

#define TAU 6.2831853
#define PI 3.1415927

// ---------------------------------------------------------------- shapes (distance, < 0 inside)
float sdSeg(vec2 p, vec2 a, vec2 b) { vec2 pa = p - a, ba = b - a; return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0)); }
float sdBox(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
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

// ---------------------------------------------------------------- clay
// The light comes from the top left. A shape is shaded by how its edge faces that light (its distance
// a step toward the light, against here), so its rim rounds over like soft clay; the middle stays flat.
const vec2 LGT = vec2(-0.6, 0.8);
const float BEV = 0.016;
vec3 clay(vec3 col, vec3 base, float d, float dl) {
  float a = (1.0 - smoothstep(-u_px, u_px, d));
  if (a <= 0.0) return col;
  float h = clamp(-d / BEV, 0.0, 1.0);
  float lit = clamp((dl - d) / (0.5 * BEV), -1.0, 1.0) * (1.0 - h);
  vec3 c = base * (0.88 + 0.12 * h) * (1.0 + 0.3 * lit);
  c += 0.16 * pow(max(lit, 0.0), 3.0);
  return mix(col, c, a);
}
// A soft shadow under a shape, down and to the right.
vec3 shade(vec3 col, float ds) { return col * (1.0 - 0.2 * (1.0 - smoothstep(-0.01, 0.02, ds))); }

// ---------------------------------------------------------------- letters
// A light geometric sans drawn as round-ended strokes: the distance to each letter's centre lines,
// cap height 1. Lowercase x-height 0.62.
float arcR(vec2 p, vec2 c, float r) { return p.x >= c.x ? abs(length(p - c) - r) : 1e3; }   // the right half of a circle
float ring(vec2 p, vec2 c, float r) { return abs(length(p - c) - r); }
float lD(vec2 p) { return min(min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), min(sdSeg(p, vec2(0.0, 1.0), vec2(0.22, 1.0)), sdSeg(p, vec2(0.0), vec2(0.22, 0.0)))), arcR(p, vec2(0.22, 0.5), 0.5)); }
float lI(vec2 p) { return sdSeg(p, vec2(0.0), vec2(0.0, 1.0)); }
float lN(vec2 p) { return min(min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.0, 1.0), vec2(0.66, 0.0))), sdSeg(p, vec2(0.66, 0.0), vec2(0.66, 1.0))); }
float lK(vec2 p) { return min(min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.02, 0.4), vec2(0.6, 1.0))), sdSeg(p, vec2(0.2, 0.6), vec2(0.62, 0.0))); }
float lE(vec2 p) { return min(min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.0, 1.0), vec2(0.5, 1.0))), min(sdSeg(p, vec2(0.0, 0.5), vec2(0.42, 0.5)), sdSeg(p, vec2(0.0), vec2(0.5, 0.0)))); }
float lL(vec2 p) { return min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.0), vec2(0.48, 0.0))); }
float ld(vec2 p) { return min(ring(p, vec2(0.29, 0.31), 0.29), sdSeg(p, vec2(0.58, 0.0), vec2(0.58, 1.0))); }
float lo(vec2 p) { return ring(p, vec2(0.3, 0.31), 0.3); }
float lf(vec2 p) {
  float d = min(sdSeg(p, vec2(0.14, 0.0), vec2(0.14, 0.74)), sdSeg(p, vec2(0.0, 0.6), vec2(0.36, 0.6)));
  vec2 c = vec2(0.36, 0.74);                                         // the hook over the top
  if (p.y >= c.y && p.x <= c.x + 0.16) d = min(d, abs(length(p - c) - 0.22));
  return min(d, sdSeg(p, vec2(0.36, 0.96), vec2(0.46, 0.93)));
}

// Each letter hops in turn through the bar: letter i of n jumps on its own 16th.
float hop(float i) {
  float ph = fract((barBeat() + 4.0) / 4.0) * 4.0 - i * 0.5;
  ph = mod(ph, 4.0);
  return p_hop * exp(-8.0 * ph) * (ph < 1.0 ? sin(min(ph, 1.0) * PI) * 2.0 + 0.4 : 0.0) * 0.12;
}

// DELL and doof along the baseline at o, cap height h; DINKI round an arc. Strokes w thick.
float wordDELL(vec2 p, vec2 o, float h) {
  vec2 q = (p - o) / h; float g = 0.36, x = 0.0, d = 1e3;
  d = min(d, lD(q - vec2(x, hop(0.0)))); x += 0.72 + g;
  d = min(d, lE(q - vec2(x, hop(1.0)))); x += 0.5 + g;
  d = min(d, lL(q - vec2(x, hop(2.0)))); x += 0.48 + g;
  d = min(d, lL(q - vec2(x, hop(3.0))));
  return d * h;
}
float wordDoof(vec2 p, vec2 o, float h) {
  vec2 q = (p - o) / h; float g = 0.14, x = 0.0, d = 1e3;
  d = min(d, ld(q - vec2(x, hop(4.0)))); x += 0.58 + g;
  d = min(d, lo(q - vec2(x, hop(5.0)))); x += 0.6 + g;
  d = min(d, lo(q - vec2(x, hop(6.0)))); x += 0.6 + g;
  d = min(d, lf(q - vec2(x, hop(7.0))));
  return d * h;
}
// One letter of DINKI, stood on the arc at angle a (radians, round centre c, radius r).
float onArc(vec2 p, vec2 c, float r, float a, float h, float w, float hopv, int which) {
  vec2 base = c + r * vec2(cos(a), sin(a));
  vec2 q = rot(PI * 0.5 - a) * (p - base) / h;                        // letter space: up is away from the centre
  q.x += w * 0.5; q.y -= hopv;
  if (which == 0) return lD(q) * h;
  if (which == 1) return lI(q) * h;
  if (which == 2) return lN(q) * h;
  if (which == 3) return lK(q) * h;
  return lI(q) * h;
}
float wordDINKI(vec2 p, vec2 c, float r, float h) {
  // Spread so the letters sit like the cover's: rising from the left, flattening at the I.
  float d = 1e3;
  // Each letter's centre along the arc, in cap heights (its width and the gap after it), turned into an angle.
  float a0 = 2.13, u = h / r;
  d = min(d, onArc(p, c, r, a0 - 0.36 * u, h, 0.72, hop(0.0), 0));
  d = min(d, onArc(p, c, r, a0 - 1.08 * u, h, 0.0, hop(1.0), 1));
  d = min(d, onArc(p, c, r, a0 - 1.77 * u, h, 0.66, hop(2.0), 2));
  d = min(d, onArc(p, c, r, a0 - 2.77 * u, h, 0.62, hop(3.0), 3));
  d = min(d, onArc(p, c, r, a0 - 3.44 * u, h, 0.0, hop(4.0), 4));
  return d;
}

// ---------------------------------------------------------------- the three
// The eye in its sunburst. Returns the shape's distance; kind tells the caller which part it hit.
float rays(vec2 q, float n, float pulse) {
  float a = atan(q.y, q.x), sec = TAU / n;
  float i = floor(a / sec + 0.5);
  vec2 r = rot(-i * sec) * q;
  float len = 0.88 + 0.12 * sin(i * 2.4) + pulse;                     // the cover's rays aren't all one length
  return sdSeg(r, vec2(0.45, 0.0), vec2(len, 0.0)) - 0.068;
}
float bee(vec2 q, float flap, out float wingD) {
  float body = min(min(sdEll(q - vec2(0.0, 0.28), vec2(0.17, 0.16)), sdEll(q - vec2(0.0, 0.02), vec2(0.2, 0.2))),
                   sdEll(q - vec2(0.0, -0.4), vec2(0.21, 0.36)));
  body = min(body, min(sdSeg(q, vec2(-0.06, 0.4), vec2(-0.16, 0.66)), sdSeg(q, vec2(0.06, 0.4), vec2(0.16, 0.66))) - 0.025);
  body = min(body, min(length(q - vec2(-0.17, 0.68)), length(q - vec2(0.17, 0.68))) - 0.05);
  vec2 m = vec2(abs(q.x), q.y);                                       // the wings and legs are mirrored
  float up = sdEll(rot(-0.35) * (m - vec2(0.48, 0.18)), vec2(0.36, 0.28 * flap));
  float lw = sdEll(rot(0.45) * (m - vec2(0.4, -0.3)), vec2(0.25, 0.2 * flap));
  wingD = min(up, lw);
  float legs = min(sdSeg(m, vec2(0.15, -0.25), vec2(0.36, -0.62)), sdSeg(m, vec2(0.12, -0.1), vec2(0.4, -0.12))) - 0.022;
  return min(body, legs);
}
// The golden disc's glyphs: a target, wavy lines, boxes, a star, a dumbbell, dots.
float glyphs(vec2 q) {
  float d = min(abs(length(q - vec2(-0.5, 0.36)) - 0.18), length(q - vec2(-0.5, 0.36)) - 0.05);
  d = min(d, abs(q.y - 0.55 - 0.05 * sin(q.x * 55.0)) + max(abs(q.x - 0.3) - 0.24, 0.0));
  d = min(d, abs(q.y - 0.32 - 0.05 * sin(q.x * 55.0)) + max(abs(q.x - 0.28) - 0.2, 0.0));
  d = min(d, abs(sdBox(q - vec2(0.3, 0.0), vec2(0.12, 0.12), 0.03)));
  d = min(d, abs(sdBox(q - vec2(0.3, -0.3), vec2(0.12, 0.12), 0.03)));
  d = min(d, abs(length(q - vec2(0.3, -0.3)) - 0.05));
  d = min(d, sdSeg(q, vec2(-0.72, -0.02), vec2(-0.28, -0.02)));
  d = min(d, sdSeg(q, vec2(-0.66, -0.12), vec2(-0.42, -0.12)));
  d = min(d, length(q - vec2(-0.08, 0.0)) - 0.07);
  vec2 s = q - vec2(-0.42, -0.48);                                    // the star
  for (int i = 0; i < 4; i++) { vec2 r = rot(float(i) * PI / 4.0) * s; d = min(d, sdSeg(r, vec2(-0.2, 0.0), vec2(0.2, 0.0))); }
  d = min(d, min(length(q - vec2(0.2, -0.62)), length(q - vec2(0.42, -0.62))) - 0.05);
  d = min(d, sdSeg(q, vec2(0.2, -0.62), vec2(0.42, -0.62)));
  return d - 0.025;
}

vec3 tint(vec3 c, float h) {                                          // turn a colour round the wheel, keeping its lightness
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  vec3 k = hsv(h, 1.0, 1.0); vec3 g = c - l;
  float a = h * TAU;
  vec3 r = l + g * cos(a) + cross(normalize(vec3(1.0)), g) * sin(a) + normalize(vec3(1.0)) * dot(normalize(vec3(1.0)), g) * (1.0 - cos(a));
  return clamp(r, 0.0, 1.0);
}

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0); p.y = -p.y;
  float k = kick() * p_beat, dr = dropArc() * p_drop;
  float fit = min(1.0, u_aspect / 1.78) * p_size;                      // narrower surfaces get a smaller copy
  vec2 q = (p - vec2(0.19 * fit, p_cy)) / fit;                       // the group is centred (the cover had credits on the right)
  // Show one of the three on its own, big and centred (a pyramid face, a small surface): 1 eye, 2 bee, 3 disc.
  float solo = floor(p_show + 0.5);
  if (solo > 0.5) {
    vec2 ci = solo < 1.5 ? vec2(-0.213, 0.005) : solo < 2.5 ? vec2(0.06, -0.005) : vec2(0.338, 0.003);
    q = ci + (p - vec2(0.0, p_cy)) * 0.135 / (0.34 * min(1.0, u_aspect) * p_size);
  }
  float hs = p_follow > 0.5 ? u_hue - 0.17 : 0.0;

  // Palette: the cover's, or a night version; Ground swaps the lime for another colour.
  vec3 LIME = vec3(0.882, 0.918, 0.482), LILAC = vec3(0.62, 0.56, 0.76), BLUE = vec3(0.0, 0.62, 0.84);
  vec3 PEACH = vec3(0.99, 0.79, 0.6), MAROON = vec3(0.36, 0.11, 0.17), GOLD = vec3(0.98, 0.76, 0.33);
  vec3 IRIS = vec3(0.3, 0.68, 0.88);
  vec3 bg = LIME;
  if (p_bg > 0.5 && p_bg < 1.5) bg = vec3(0.98, 0.72, 0.78);           // 1 pink
  else if (p_bg > 1.5 && p_bg < 2.5) bg = vec3(0.55, 0.85, 0.95);      // 2 sky
  else if (p_bg > 2.5) bg = vec3(0.08, 0.06, 0.16);                    // 3 night
  if (p_ink > 0.5) { LILAC = vec3(1.0, 0.45, 0.75); BLUE = vec3(0.2, 0.95, 0.85); PEACH = vec3(1.0, 0.86, 0.45); }   // neon inks
  if (hs != 0.0) { bg = tint(bg, hs); BLUE = tint(BLUE, hs); }
  bg *= 1.0 + 0.08 * dr;
  vec3 col = bg;

  // ---- the tube: a thick blue line wandering in from the left and along the bottom, wobbling on the beat
  if (p_tube > 0.5) {
    vec2 t = p;                                                        // its own frame: the whole surface, not the fitted copy
    float best = 1e3, bestL = 1e3, bestS = 1e3;
    float wob = 0.03 * sin(u_beat * PI * 0.5) + 0.02 * k;
    float x0 = -0.5 * u_aspect - 0.1, x1 = 0.5 * u_aspect + 0.1, N = 40.0;
    float i0 = floor((t.x - x0) / (x1 - x0) * N);
    for (int j = -3; j <= 3; j++) {                                    // the curve runs left to right, so only its nearby pieces matter
      float s0 = (i0 + float(j)) / N, s1 = s0 + 1.0 / N;
      vec2 a0 = vec2(mix(x0, x1, s0), -0.12 - 0.3 * s0 + 0.2 * sin(s0 * 9.0 + 1.2) * (1.0 - 0.4 * s0) + wob * sin(s0 * 7.0 + u_beat));
      vec2 b0 = vec2(mix(x0, x1, s1), -0.12 - 0.3 * s1 + 0.2 * sin(s1 * 9.0 + 1.2) * (1.0 - 0.4 * s1) + wob * sin(s1 * 7.0 + u_beat));
      best = min(best, sdSeg(t, a0, b0));
      bestL = min(bestL, sdSeg(t + LGT * 0.01, a0, b0));
      bestS = min(bestS, sdSeg(t - vec2(0.012, -0.018), a0, b0));
    }
    float R = 0.026;
    col = shade(col, bestS - R);
    float a = (1.0 - smoothstep(-u_px, u_px, best - R));
    if (a > 0.0) {                                                     // round across: a tube, lit from above
      float n = clamp(best / R, 0.0, 1.0), side = clamp((bestL - best) / 0.01, -1.0, 1.0);
      vec3 c = BLUE * (0.62 + 0.38 * sqrt(1.0 - n * n)) * (1.0 + 0.25 * side);
      c += 0.35 * pow(max(side, 0.0), 6.0) * (1.0 - n);
      col = mix(col, c, a);
    }
  }

  // ---- the lettering
  if (p_text > 0.5 && solo < 0.5) {
    float w = 0.0085;
    if (q.x < -0.24 && q.x > -1.0 && q.y > -0.14 && q.y < 0.36) {
      float d = min(min(wordDELL(q, vec2(-0.575, -0.035), 0.072), wordDoof(q, vec2(-0.47, -0.1), 0.052)),
                    wordDINKI(q, vec2(-0.35, -0.74), 0.92, 0.11)) - w;
      float dl = min(min(wordDELL(q + LGT * 0.004, vec2(-0.575, -0.035), 0.072), wordDoof(q + LGT * 0.004, vec2(-0.47, -0.1), 0.052)),
                     wordDINKI(q + LGT * 0.004, vec2(-0.35, -0.74), 0.92, 0.11)) - w;
      col = mix(col, LILAC * (1.0 + 0.15 * clamp((dl - d) / 0.002, -1.0, 1.0)), (1.0 - smoothstep(-u_px, u_px, d)));
    }
  }

  if (p_icons > 0.5) {
    float bob = p_bob * 0.012;
    // ---- the eye in its sunburst
    vec2 c1 = vec2(-0.213, 0.005 + bob * sin(u_beat * PI * 0.5));
    vec2 e = (q - c1) / (0.135 * (1.0 + 0.05 * k + 0.15 * dr));
    if (dot(e, e) < 2.0 && (solo < 0.5 || solo < 1.5)) {              // the rays reach about 1.1, 1.4 on the drop
      vec2 er = rot(u_beat * p_spin * TAU / 64.0) * e;
      float pulse = 0.08 * k + 0.25 * dr;
      float rd = rays(er, 22.0, pulse);
      col = shade(col, rays(rot(u_beat * p_spin * TAU / 64.0) * (e - vec2(0.09, -0.13)), 22.0, pulse) * 0.135);
      col = clay(col, PEACH, rd * 0.135, rays(er + LGT * 0.06, 22.0, pulse) * 0.135);
      vec2 A = vec2(0.0, 0.42), B = vec2(0.5, -0.36), C = vec2(-0.5, -0.36);
      float td = sdTri(e, A, B, C) * 0.135 - 0.004;
      col = shade(col, sdTri(e - vec2(0.06, -0.09), A, B, C) * 0.135);
      col = clay(col, PEACH * 1.02, td, sdTri(e + LGT * 0.06, A, B, C) * 0.135 - 0.004);
      // The eye: an almond of white, a blue iris that looks about, a dark pupil, a glint. It blinks.
      float blink = smoothstep(0.92, 1.0, fract(u_beat / 16.0)) * (1.0 - smoothstep(0.98, 1.0, fract(u_beat / 16.0)));
      float open = max(0.0, 1.0 - 2.0 * blink + 0.25 * dr);
      vec2 ey = e - vec2(0.0, -0.06);
      float white = sdEll(ey, vec2(0.3, 0.17 * open + 0.001)) * 0.135;
      col = clay(col, vec3(0.98, 0.97, 0.94), white, sdEll(ey + LGT * 0.06, vec2(0.3, 0.17 * open + 0.001)) * 0.135);
      if (white < 0.0) {
        vec2 look = 0.06 * vec2(sin(u_beat * 0.37), 0.4 * sin(u_beat * 0.23)) * (1.0 - dr);
        float iris = (length(ey - look) - 0.14) * 0.135, pupil = (length(ey - look) - 0.065 * (1.0 - 0.3 * dr)) * 0.135;
        col = mix(col, IRIS * (0.75 + 0.35 * clamp(1.0 - length(ey - look - vec2(-0.04, 0.04)) * 6.0, 0.0, 1.0)), (1.0 - smoothstep(-u_px, u_px, iris)));
        col = mix(col, vec3(0.08, 0.1, 0.14), (1.0 - smoothstep(-u_px, u_px, pupil)));
        col = mix(col, vec3(1.0), (1.0 - smoothstep(-u_px, u_px, (length(ey - look - vec2(-0.05, 0.05)) - 0.025) * 0.135)));
      }
    }
    // ---- the bee, wings flapping on the beat
    vec2 c2 = vec2(0.06, -0.005 + bob * sin(u_beat * PI * 0.5 + 2.0));
    vec2 b = (q - c2) / (0.15 * (1.0 + 0.04 * k + 0.12 * dr));
    if (dot(b, b) < 1.4 && (solo < 0.5 || abs(solo - 2.0) < 0.5)) {
      float flap = 1.0 - 0.45 * exp(-10.0 * u_frac) * step(0.01, p_beat);
      float wD, wDl, wDs;
      float bd = bee(b, flap, wD), bdl = bee(b + LGT * 0.05, flap, wDl), bds = bee(b - vec2(0.07, -0.1), flap, wDs);
      col = shade(col, min(bds, wDs) * 0.15);
      // The cover's bee is quilted: a fine dot grid pressed into the maroon.
      vec2 g = fract(b * 26.0) - 0.5;
      vec3 quilt = MAROON * (0.92 + 0.16 * (1.0 - smoothstep(0.15, 0.35, length(g))));
      col = clay(col, quilt * 1.08, wD * 0.15, wDl * 0.15);
      col = clay(col, quilt, bd * 0.15, bdl * 0.15);
    }
    // ---- the golden disc of glyphs, turning slowly
    vec2 c3 = vec2(0.338, 0.003 + bob * sin(u_beat * PI * 0.5 + 4.0));
    vec2 g3 = (q - c3) / (0.137 * (1.0 + 0.04 * k + 0.12 * dr));
    if (dot(g3, g3) < 1.3 && (solo < 0.5 || solo > 2.5)) {
      float dd = (length(g3) - 1.0) * 0.137;
      col = shade(col, (length(g3 - vec2(0.07, -0.1)) - 1.0) * 0.137);
      col = clay(col, GOLD, dd, (length(g3 + LGT * 0.06) - 1.0) * 0.137);
      if (dd < 0.0) {                                                  // the glyphs, raised from the disc
        vec2 r3 = rot(u_beat * p_spin * TAU / 128.0) * g3;
        float gd = glyphs(r3 * 1.12) * 0.12, gdl = glyphs((r3 + LGT * 0.04) * 1.12) * 0.12;
        float lit = clamp((gdl - gd) / 0.003, -1.0, 1.0);
        float edge = (1.0 - smoothstep(-u_px, u_px, gd)) * (1.0 - smoothstep(0.0, 0.006, -gd));
        col *= 1.0 + 0.22 * lit * edge;
        col = mix(col, col * (1.0 + 0.12 * k), (1.0 - smoothstep(-u_px, u_px, gd)));
      }
    }
  }
  return clamp(col * p_bright, 0.0, 1.0);
}
