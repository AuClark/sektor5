// Sphinx: the Great Sphinx side on, lying in the sand, in soft clay, for the Dinki Dell doof. Its
// headdress is striped gold and blue, a big sun sits behind its head and the pyramids stand small on
// the horizon. On the beat the stripes ripple down the headdress and the eye looks round and blinks;
// through a build the eye glows hotter, and on the drop it fires lasers across the screen.
// Each part only works out its detail near itself, so most of the screen is a flat colour.
// Params are p_* uniforms; ranges and defaults are in sphinx.json.
uniform float p_size, p_cx, p_cy, p_sun, p_pyr, p_stripes, p_ripple, p_look, p_laser, p_beat,
              p_drop, p_pal, p_follow, p_bright;

#define TAU 6.2831853
#define PI 3.1415927

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
float smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }

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

// The lion: lying down facing left, the haunch at the back, the chest high, the forelegs out in front.
float body(vec2 p) {
  float d = sdBox(p - vec2(0.2, -0.11), vec2(0.33, 0.09), 0.09);                // the back and belly
  d = smin(d, sdEll(p - vec2(0.44, -0.07), vec2(0.17, 0.115)), 0.08);             // the haunch
  d = smin(d, sdEll(p - vec2(-0.12, -0.03), vec2(0.15, 0.17)), 0.07);             // the chest
  d = smin(d, sdBox(p - vec2(-0.36, -0.175), vec2(0.22, 0.032), 0.03), 0.04);      // the near foreleg
  d = min(d, sdEll(p - vec2(-0.59, -0.18), vec2(0.05, 0.032)));                   // its paw
  d = min(d, sdSeg(p, vec2(0.6, -0.17), vec2(0.7, -0.195)) - 0.013);             // the tail along the ground
  return d;
}
float farLeg(vec2 p) {                                                            // the other foreleg, a step behind
  return min(sdBox(p - vec2(-0.33, -0.14), vec2(0.2, 0.03), 0.03), sdEll(p - vec2(-0.54, -0.145), vec2(0.045, 0.03)));
}
// The head lives in its own space (h), drawn at this size and scaled up onto the chest by HS.
const float HS = 1.2;
const vec2 HC = vec2(-0.17, 0.15), HP = vec2(-0.12, 0.12);
vec2 headSpace(vec2 q) { return (q - HC) / HS + HP; }
// The headdress (nemes): a dome over the crown, side flaps flaring down to the chest, the tail behind.
float nemes(vec2 h) {
  float d = sdEll(h - vec2(-0.125, 0.215), vec2(0.115, 0.1));
  d = smin(d, sdTri(h, vec2(-0.2, 0.19), vec2(-0.03, 0.22), vec2(0.0, -0.04)), 0.02);
  d = smin(d, sdTri(h, vec2(-0.2, 0.19), vec2(0.0, -0.04), vec2(-0.19, -0.05)), 0.02);
  d = smin(d, sdTri(h, vec2(-0.05, 0.2), vec2(0.04, 0.16), vec2(0.03, 0.02)), 0.02);    // the tail of the cloth
  return d;
}
// The face, in profile looking left: brow, nose, lips, chin and the false beard.
float face(vec2 h) {
  float d = sdEll(h - vec2(-0.215, 0.135), vec2(0.065, 0.09));
  d = smin(d, sdTri(h, vec2(-0.262, 0.165), vec2(-0.29, 0.12), vec2(-0.25, 0.115)), 0.008);   // the nose
  d = smin(d, sdEll(h - vec2(-0.245, 0.078), vec2(0.03, 0.024)), 0.012);                      // lips and chin
  d = smin(d, sdBox(h - vec2(-0.228, 0.04), vec2(0.014, 0.026), 0.01), 0.012);                // the false beard
  return d;
}
// A small pyramid on the horizon.
float far(vec2 p, vec2 b, float w, float h) { return sdTri(p, b + vec2(0.0, h), b - vec2(w, 0.0), b + vec2(w, 0.0)); }

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0); p.y = -p.y;
  float k = kick() * p_beat, dr = dropArc() * p_drop;
  float build = clamp(u_progress, 0.0, 1.0) * step(3.5, u_scene) * step(u_scene, 5.5);
  float fit = min(1.0, u_aspect / 1.6) * p_size;
  vec2 q = (p - vec2(p_cx, p_cy)) / fit;
  float hs = p_follow > 0.5 ? u_hue - 0.1 : 0.0;

  // Palettes: 0 desert, 1 the cover (lime sky), 2 night, 3 pink.
  vec3 SKY = vec3(0.55, 0.82, 0.96), SKY2 = vec3(0.99, 0.82, 0.6), SAND = vec3(0.98, 0.78, 0.48), SUN = vec3(1.0, 0.88, 0.45);
  vec3 STONE = vec3(0.96, 0.74, 0.47), GOLD = vec3(0.99, 0.78, 0.3), LAPIS = vec3(0.12, 0.36, 0.78), FAR = vec3(0.93, 0.66, 0.42);
  vec3 LASER = vec3(1.0, 0.15, 0.25);
  if (p_pal > 0.5 && p_pal < 1.5) { SKY = vec3(0.882, 0.918, 0.482); SKY2 = vec3(0.9, 0.92, 0.55); SUN = vec3(0.99, 0.79, 0.6); STONE = vec3(0.99, 0.8, 0.62); LAPIS = vec3(0.62, 0.56, 0.76); FAR = vec3(0.86, 0.82, 0.5); }
  else if (p_pal > 1.5 && p_pal < 2.5) { SKY = vec3(0.08, 0.05, 0.2); SKY2 = vec3(0.32, 0.1, 0.42); SAND = vec3(0.24, 0.12, 0.36); SUN = vec3(1.0, 0.45, 0.75); STONE = vec3(0.35, 0.85, 0.9); GOLD = vec3(1.0, 0.85, 0.35); LAPIS = vec3(0.55, 0.2, 0.9); FAR = vec3(0.3, 0.2, 0.55); LASER = vec3(0.3, 1.0, 0.5); }
  else if (p_pal > 2.5) { SKY = vec3(0.99, 0.75, 0.82); SKY2 = vec3(1.0, 0.86, 0.7); SUN = vec3(1.0, 0.95, 0.6); STONE = vec3(0.99, 0.84, 0.72); LAPIS = vec3(0.9, 0.35, 0.55); FAR = vec3(0.95, 0.65, 0.65); }
  if (hs != 0.0) { vec3 o = hsv(fract(hs), 0.3, 1.0); o /= max(max(o.r, o.g), o.b); SKY *= o; SKY2 *= o; }

  float horizon = -0.2;
  vec3 col = mix(SKY2, SKY, smoothstep(horizon - 0.05, 0.5, q.y)) * (1.0 + 0.12 * dr);

  // ---- the sun behind its head, swelling on the kick
  vec2 sc = vec2(-0.1, 0.24);
  if (p_sun > 0.5 && length(q - sc) < 0.45) {
    float sr = 0.32 + 0.008 * k + 0.03 * dr;
    col = clay(col, SUN, length(q - sc) - sr, length(q - sc + LGT * 0.01) - sr);
  }
  // ---- the pyramids small on the horizon
  if (p_pyr > 0.5 && q.y < horizon + 0.2 && q.y > horizon - 0.02) {
    vec2 b1 = vec2(0.62, horizon), b2 = vec2(0.82, horizon);
    float fd = min(far(q, b1, 0.13, 0.17), far(q, b2, 0.09, 0.12));
    col = clay(col, FAR, fd, min(far(q + LGT * 0.006, b1, 0.13, 0.17), far(q + LGT * 0.006, b2, 0.09, 0.12)));
  }
  // ---- the sand
  float gy = horizon + 0.012 * sin(q.x * 6.0);
  col = clay(col, SAND, q.y - gy, q.y + 0.008 - gy);

  // ---- the lion's body
  if (q.x > -0.7 && q.x < 0.8 && q.y > -0.3 && q.y < 0.14) {
    col = clay(col, STONE * 0.86, farLeg(q), farLeg(q + LGT * 0.008));
    col = shade(col, body(q - vec2(0.035, -0.02)), 0.22);
    col = clay(col, STONE, body(q), body(q + LGT * 0.008));
  }
  // ---- the head: headdress, face, eye
  if (q.x > -0.4 && q.x < 0.14 && q.y > -0.1 && q.y < 0.5) {
    vec2 h = headSpace(q), hl = headSpace(q + LGT * 0.008), hsd = headSpace(q - vec2(0.03, -0.02));
    col = shade(col, nemes(hsd) * HS, 0.2);
    float nd = nemes(h) * HS;
    // Stripes run down the cloth; on the beat a ripple of light travels down them.
    float sy = (h.y - 0.3) * 1.0 + (h.x + 0.12) * 0.35;
    float st = step(0.5, fract(sy * p_stripes));
    vec3 cloth = mix(GOLD, LAPIS, st);
    float rip = p_ripple * exp(-abs(fract(-sy * 0.8 - u_frac * 0.9) - 0.5) * 9.0) * (0.4 + 0.6 * k);
    cloth *= 1.0 + 0.5 * rip;
    col = clay(col, cloth, nd, nemes(hl) * HS);
    float fd = face(h) * HS;
    col = shade(col, face(headSpace(q - vec2(0.015, -0.01))) * HS, 0.18);
    col = clay(col, STONE, fd, face(hl) * HS);
    // The eye: an almond with a long dark line of kohl, the iris looking round. It glows through a
    // build and fires on the drop.
    vec2 ec = vec2(-0.235, 0.15);
    vec2 e = h - ec;
    float blink = smoothstep(0.93, 1.0, fract(u_beat / 16.0)) * (1.0 - smoothstep(0.98, 1.0, fract(u_beat / 16.0)));
    float open = max(0.05, 1.0 - 2.0 * blink);
    float ed = sdEll(e, vec2(0.022, 0.011 * open));
    col = mix(col, vec3(0.1, 0.08, 0.12), (1.0 - smoothstep(-u_px, u_px, min(abs(ed) - 0.0025, sdSeg(e, vec2(0.018, 0.002), vec2(0.042, -0.002)) - 0.0022))));
    col = mix(col, vec3(0.99, 0.97, 0.92), (1.0 - smoothstep(-u_px, u_px, ed)));
    if (ed < 0.0) {
      vec2 look = vec2(-0.008 + 0.006 * sin(u_beat * 0.37) * p_look, 0.002 * sin(u_beat * 0.23) * p_look);
      vec3 iris = mix(vec3(0.15, 0.1, 0.08), LASER, max(build, dr));
      col = mix(col, iris, (1.0 - smoothstep(-u_px, u_px, length(e - look) - 0.009)));
    }
    col += LASER * exp(-length(e) * HS / 0.02) * (0.6 * build + 1.2 * dr) * p_laser;
  }
  // ---- the lasers: on the drop, from the eye across the screen to the left, flickering on the 16ths
  if (p_laser > 0.0 && dr > 0.01) {
    vec2 ec = HC + (vec2(-0.235, 0.15) - HP) * HS;
    float fl = 0.75 + 0.25 * step(0.5, fract(u_beat * 4.0));
    for (int i = 0; i < 2; i++) {
      float ang = (i == 0 ? 0.04 : -0.06) + 0.05 * sin(u_beat * 0.5 + float(i));
      vec2 dir = vec2(-cos(ang), sin(ang));
      vec2 r = q - ec;
      float along = dot(r, dir), off = abs(dot(r, vec2(-dir.y, dir.x)));
      if (along > 0.0) col += LASER * (exp(-off / 0.003) * 1.2 + exp(-off / 0.02) * 0.4) * dr * fl * p_laser;
    }
  }
  return clamp(col * p_bright, 0.0, 1.0);
}
