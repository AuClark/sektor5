// Astronaut: a chunky clay astronaut floating in a bright sky, for the Dinki Dell doof, tethered by the
// cover's blue tube. A ringed planet and a moon hang behind, the stars twinkle on the beat, one arm
// waves and the chest buttons light in turn; the visor reflects a studio spotlight (it was all filmed
// on a set). On the drop the astronaut does a full flip, the visor shows the all-seeing eye and the
// stars burst. Each part only works out its detail near itself, so most of the screen is a flat colour.
// Params are p_* uniforms; ranges and defaults are in astronaut.json.
uniform float p_size, p_cx, p_cy, p_drift, p_wave, p_stars, p_planet, p_tether, p_flip, p_beat,
              p_drop, p_pal, p_follow, p_bright;

#define TAU 6.2831853
#define PI 3.1415927

float sdSeg(vec2 p, vec2 a, vec2 b) { vec2 pa = p - a, ba = b - a; return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0)); }
float sdBox(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
float sdEll(vec2 p, vec2 r) { return (length(p / r) - 1.0) * min(r.x, r.y); }
float smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }
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

// The astronaut, in its own space (a = arm wave 0..1). Parts: 0 suit, 1 backpack, 2 helmet.
float pack(vec2 p) { return sdBox(p - vec2(0.0, -0.05), vec2(0.15, 0.13), 0.05); }
float suit(vec2 p, float a) {
  float d = sdBox(p - vec2(0.0, -0.1), vec2(0.11, 0.12), 0.07);                      // the torso
  // Arms: the right one (its left, on screen right) waves; the other floats.
  vec2 hR = vec2(0.24, 0.0) + vec2(0.02, 0.12) * a, hL = vec2(-0.23, -0.12);
  d = smin(d, sdSeg(p, vec2(0.1, -0.03), hR) - 0.045, 0.03);
  d = smin(d, sdSeg(p, vec2(-0.1, -0.03), hL) - 0.045, 0.03);
  d = min(d, min(length(p - hR), length(p - hL)) - 0.05);                           // gloves
  // Legs and boots, a little apart.
  d = smin(d, sdSeg(p, vec2(-0.06, -0.2), vec2(-0.1, -0.33)) - 0.05, 0.03);
  d = smin(d, sdSeg(p, vec2(0.06, -0.2), vec2(0.11, -0.32)) - 0.05, 0.03);
  d = min(d, min(sdEll(p - vec2(-0.11, -0.37), vec2(0.07, 0.04)), sdEll(p - vec2(0.12, -0.36), vec2(0.07, 0.04))));
  return d;
}
float helmet(vec2 p) { return length(p - vec2(0.0, 0.14)) - 0.165; }

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0); p.y = -p.y;
  float k = kick() * p_beat, dr = dropArc() * p_drop;
  float fit = min(1.0, u_aspect / 1.4) * p_size;
  float hs = p_follow > 0.5 ? u_hue - 0.17 : 0.0;

  // Palettes: 0 the cover (lime), 1 space (navy, neon), 2 pink, 3 sky.
  vec3 BG = vec3(0.882, 0.918, 0.482), SUIT = vec3(0.97, 0.96, 0.93), PACK = vec3(0.86, 0.85, 0.82), TUBE = vec3(0.0, 0.62, 0.84);
  vec3 PLANET = vec3(0.62, 0.56, 0.76), RING = vec3(0.99, 0.79, 0.6), MOON = vec3(0.98, 0.76, 0.33), STAR = vec3(1.0);
  vec3 VIS = vec3(0.12, 0.1, 0.25), VIS2 = vec3(0.45, 0.3, 0.75);
  if (p_pal > 0.5 && p_pal < 1.5) { BG = vec3(0.07, 0.06, 0.2); PLANET = vec3(1.0, 0.45, 0.75); RING = vec3(0.3, 0.95, 0.85); TUBE = vec3(0.3, 0.95, 0.85); MOON = vec3(1.0, 0.86, 0.45); STAR = vec3(1.0, 0.95, 0.7); }
  else if (p_pal > 1.5 && p_pal < 2.5) { BG = vec3(0.98, 0.72, 0.78); PLANET = vec3(0.55, 0.4, 0.85); RING = vec3(1.0, 0.9, 0.5); }
  else if (p_pal > 2.5) { BG = vec3(0.55, 0.85, 0.95); PLANET = vec3(0.98, 0.6, 0.4); RING = vec3(1.0, 0.95, 0.75); MOON = vec3(1.0, 1.0, 0.95); }
  if (hs != 0.0) { vec3 o = hsv(fract(hs), 0.3, 1.0); BG *= o / max(max(o.r, o.g), o.b); }
  vec3 col = BG * (1.0 + 0.08 * dr);

  // ---- stars: one in some cells of a grid, a four-point twinkle, brighter on the kick; they burst outward on the drop
  if (p_stars > 0.0) {
    vec2 sp = p / (1.0 + 0.6 * dr);
    vec2 cell = floor(sp * 7.0), f = fract(sp * 7.0) - 0.5;
    float hh = hash(cell);
    if (hh > 0.55) {
      vec2 o = (vec2(hash(cell + 3.1), hash(cell + 7.7)) - 0.5) * 0.6;
      vec2 d = abs(f - o);
      float tw = 0.5 + 0.5 * sin(u_beat * PI * 0.5 + hh * 20.0);
      float sz = (0.1 + 0.08 * tw + 0.12 * k * step(0.8, hh)) * p_stars;
      float star = max((1.0 - smoothstep(0.0, sz, d.x + d.y * 6.0)), (1.0 - smoothstep(0.0, sz, d.y + d.x * 6.0)));
      col = mix(col, STAR, star);
    }
  }
  // ---- a ringed planet, upper left, and the moon, lower right
  if (p_planet > 0.5) {
    vec2 pc = (p - vec2(-0.55, 0.22) * vec2(min(u_aspect / 1.78, 1.0), 1.0)) / fit;
    if (dot(pc, pc) < 0.12) {
      vec2 rr = rot(0.35) * pc;
      float ring = abs(sdEll(rr, vec2(0.21, 0.05))) - 0.012;
      float back = step(0.0, rr.y);                                    // the ring goes behind the planet at the top
      if (back > 0.5) col = clay(col, RING, ring, abs(sdEll(rr + LGT * 0.01, vec2(0.21, 0.05))) - 0.012);
      float pd = length(pc) - 0.12;
      col = clay(col, PLANET, pd, length(pc + LGT * 0.01) - 0.12);
      col = mix(col, col * 0.9, (1.0 - smoothstep(-u_px, u_px, pd)) * step(0.5, fract((pc.y + pc.x * 0.3) * 14.0)) * 0.6);   // bands
      if (back < 0.5) col = clay(col, RING, ring, abs(sdEll(rr + LGT * 0.01, vec2(0.21, 0.05))) - 0.012);
    }
    vec2 mc = (p - vec2(0.58, -0.25) * vec2(min(u_aspect / 1.78, 1.0), 1.0)) / fit;
    if (dot(mc, mc) < 0.03) {
      float md = length(mc) - 0.07;
      col = clay(col, MOON, md, length(mc + LGT * 0.01) - 0.07);
      col *= 1.0 - 0.12 * (1.0 - smoothstep(-u_px, u_px, length(mc - vec2(0.02, 0.015)) - 0.018));   // craters
      col *= 1.0 - 0.12 * (1.0 - smoothstep(-u_px, u_px, length(mc - vec2(-0.025, -0.02)) - 0.012));
    }
  }

  // ---- where the astronaut is: drifting, tilting, flipping once on the drop
  vec2 c = vec2(p_cx, p_cy) + p_drift * vec2(0.04 * sin(u_beat * PI / 16.0), 0.025 * sin(u_beat * PI / 8.0));
  float flip = p_flip * (abs(u_scene - 7.0) < 0.5 ? smoothstep(0.0, 4.0, u_since) * TAU : 0.0);
  float tilt = p_drift * 0.18 * sin(u_beat * PI / 16.0 + 1.0) + flip;
  vec2 a = rot(-tilt) * (p - c) / fit;
  vec2 al = rot(-tilt) * (p - c + LGT * 0.008 * fit) / fit;
  vec2 as = rot(-tilt) * (p - c - vec2(0.025, -0.02) * fit) / fit;
  float wave = p_wave * (0.5 + 0.5 * sin(u_beat * PI));               // up and down once every two beats

  // ---- the tether: the cover's blue tube, from the backpack off to the bottom right, swaying
  if (p_tether > 0.5) {
    vec2 t0 = c + rot(tilt) * (vec2(0.12, -0.08) * fit);
    float x0 = t0.x, x1 = 0.5 * u_aspect + 0.1, N = 30.0;
    if (p.x > x0 - 0.06) {
      float i0 = floor((p.x - x0) / (x1 - x0) * N), best = 1e3, bestL = 1e3;
      for (int j = -3; j <= 3; j++) {
        float s0 = (i0 + float(j)) / N, s1 = s0 + 1.0 / N;
        if (s1 < 0.0 || s0 > 1.0) continue;
        s0 = max(s0, 0.0); s1 = min(s1, 1.0);
        vec2 A = vec2(mix(x0, x1, s0), t0.y - 0.42 * s0 * s0 + 0.08 * sin(s0 * 7.0 + u_beat * 0.5) * s0);
        vec2 B = vec2(mix(x0, x1, s1), t0.y - 0.42 * s1 * s1 + 0.08 * sin(s1 * 7.0 + u_beat * 0.5) * s1);
        best = min(best, sdSeg(p, A, B)); bestL = min(bestL, sdSeg(p + LGT * 0.008, A, B));
      }
      float R = 0.02;
      float am = (1.0 - smoothstep(-u_px, u_px, best - R));
      if (am > 0.0) {
        float n = clamp(best / R, 0.0, 1.0), side = clamp((bestL - best) / 0.008, -1.0, 1.0);
        vec3 tc = TUBE * (0.62 + 0.38 * sqrt(1.0 - n * n)) * (1.0 + 0.25 * side) + 0.3 * pow(max(side, 0.0), 6.0) * (1.0 - n);
        col = mix(col, tc, am);
      }
    }
  }

  // ---- the astronaut
  if (dot(a, a) < 0.36) {
    col = shade(col, min(min(pack(as), suit(as, wave)), helmet(as)) * fit, 0.2);
    col = clay(col, PACK, pack(a) * fit, pack(al) * fit);
    col = clay(col, SUIT, suit(a, wave) * fit, suit(al, wave) * fit);
    // The belt and the chest panel: three buttons lighting in turn, one a beat.
    col = mix(col, PACK, (1.0 - smoothstep(-u_px, u_px, (abs(a.y + 0.17) - 0.012) * fit)) * step(abs(a.x), 0.115));
    float pd = sdBox(a - vec2(0.0, -0.07), vec2(0.06, 0.035), 0.012) * fit;
    col = clay(col, vec3(0.75, 0.75, 0.78), pd, sdBox(al - vec2(0.0, -0.07), vec2(0.06, 0.035), 0.012) * fit);
    float bb = barBeat(), on = floor(mod(bb, 3.0));
    for (int i = 0; i < 3; i++) {
      vec3 bc = i == 0 ? vec3(1.0, 0.3, 0.35) : i == 1 ? vec3(1.0, 0.85, 0.2) : vec3(0.2, 0.7, 1.0);
      float lit = abs(float(i) - on) < 0.5 ? 1.0 + 0.6 * kick() : 0.45;
      col = mix(col, bc * lit, (1.0 - smoothstep(-u_px, u_px, (length(a - vec2(-0.034 + 0.034 * float(i), -0.07)) - 0.013) * fit)));
    }
    // The helmet and its visor: a dark glass that reflects a studio spotlight; on the drop, the eye.
    float hd = helmet(a) * fit;
    col = clay(col, SUIT, hd, helmet(al) * fit);
    vec2 v = a - vec2(0.0, 0.14);
    float vd = sdEll(v, vec2(0.125, 0.095)) * fit;
    if (vd < u_px) {
      vec3 vc = mix(VIS2, VIS, smoothstep(-0.09, 0.08, v.y - v.x * 0.4));
      // The reflection: a spotlight cone swinging across the glass, the set's lights at the top.
      float sw = 0.06 * sin(u_beat * PI / 4.0);
      float cone = (1.0 - smoothstep(0.0, 0.02, abs(v.x - sw - (v.y - 0.08) * 0.5) - (0.08 - v.y) * 0.25)) * step(v.y, 0.08);
      vc += vec3(1.0, 0.95, 0.8) * cone * 0.35 * (1.0 - dr);
      vc += vec3(1.0) * (1.0 - smoothstep(0.0, 0.012, length(v - vec2(sw, 0.075)) - 0.008)) * (1.0 - dr);
      // On the drop the eye looks out of the glass.
      if (dr > 0.01) {
        vec2 e = v / 0.07;
        float white = sdEll(e, vec2(1.0, 0.55 * dr));
        vc = mix(vc, vec3(0.98, 0.96, 0.92), (1.0 - smoothstep(-0.03, 0.03, white)));
        vc = mix(vc, vec3(0.3, 0.68, 0.88), (1.0 - smoothstep(-0.03, 0.03, length(e) - 0.42)) * step(white, 0.0));
        vc = mix(vc, vec3(0.06, 0.07, 0.1), (1.0 - smoothstep(-0.03, 0.03, length(e) - 0.2)) * step(white, 0.0));
      }
      vc += 0.5 * (1.0 - smoothstep(0.0, 0.03, length(v - vec2(-0.06, 0.05)) - 0.01));   // a glint on the glass
      col = mix(col, vc, (1.0 - smoothstep(-u_px, u_px, vd)));
      col = mix(col, col * 0.8, (1.0 - smoothstep(-u_px, u_px, abs(vd) - 0.004)));      // the rim of the glass
    }
  }
  return clamp(col * p_bright, 0.0, 1.0);
}
