// Doof: the Dinki Dell doof holding screen, after the event's cover, made for a triangle (a pyramid
// face): one icon big in the middle, turning like a coin every few bars from the eye in its sunburst to
// the quilted bee to the golden disc (or one of them held),
// DINKI DELL and doof across the wide part at the bottom, soft clay on a flat colour. Nothing sits
// near the sides or the top, so a trimmed triangle still shows it all.
// On the beat: the letters hop in turn, the rays pulse, the bee flaps, the eye looks and blinks.
// On the drop: the icon swells and the rays burst.
// Params are p_* uniforms; ranges and defaults are in doof.json.
uniform float p_show, p_every, p_size, p_cy, p_text, p_hop, p_spin, p_beat, p_drop, p_pal, p_follow, p_bright,
              p_trip, p_echo, p_melt, p_cycle;

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
mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }
float fill(float d) { return 1.0 - smoothstep(-u_px, u_px, d); }           // 1 inside a shape, anti-aliased

// ---------------------------------------------------------------- trip: the psychedelic layer
// Turn a colour round the colour wheel, keeping its brightness (in YIQ).
vec3 rotHue(vec3 c, float a) {
  vec3 y = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312) * c;
  float cs = cos(a * 6.2831853), sn = sin(a * 6.2831853);
  y.yz = vec2(y.y * cs - y.z * sn, y.y * sn + y.z * cs);
  return clamp(mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703) * y, 0.0, 1.0);
}
// The ground as a two-tone spiral (bg and b2) turning out of p = 0, rings flowing outward a beat at a time.
vec3 spiral(vec3 bg, vec3 b2, vec2 p, float amt) {
  if (amt <= 0.0) return bg;
  float r = length(p) + 1e-3, a = atan(p.y, p.x + 1e-5), lr = log(r);
  float arms = sin(a * 5.0 + lr * 5.0 - u_beat * 0.785);               // five arms, a twentieth of a turn a beat
  float rings = sin(lr * 9.0 - u_beat * 3.1416);                         // a ring of light out from the middle every two beats
  float m = smoothstep(-0.05, 0.05, arms) * clamp(amt, 0.0, 1.0);
  return mix(bg, b2, m) * (1.0 + amt * (0.07 * rings + 0.1 * kick() * m));
}
// Lines rippling out from a shape (its distance d, outside it) once a beat, fainter on the off-beat.
float echo(float d) {
  float e = 0.0;
  for (int i = 0; i < 2; i++) {
    float ph = fract(u_frac + 0.5 * float(i));
    e += exp(-abs(d - ph * 0.14) / 0.0035) * (1.0 - ph) * (i == 0 ? 1.0 : 0.5);
  }
  return e * step(0.0, d);
}
// A slow liquid wobble.
vec2 melt(vec2 q, float amt) { return q + amt * 0.012 * vec2(sin(q.y * 17.0 + u_beat * 1.5708), sin(q.x * 17.0 + u_beat * 1.5708 + 1.7)); }

// Clay: a shape shaded by how its rim faces the light (top left), flat in the middle, and a soft shadow.
const vec2 LGT = vec2(-0.6, 0.8);
const float BEV = 0.016;
vec3 clay(vec3 col, vec3 base, float d, float dl) {
  float a = fill(d);
  if (a <= 0.0) return col;
  float h = clamp(-d / BEV, 0.0, 1.0);
  float lit = clamp((dl - d) / (0.5 * BEV), -1.0, 1.0) * (1.0 - h);
  vec3 c = base * (0.88 + 0.12 * h) * (1.0 + 0.3 * lit) + 0.16 * pow(max(lit, 0.0), 3.0);
  return mix(col, c, a);
}
vec3 shade(vec3 col, float ds) { return col * (1.0 - 0.2 * (1.0 - smoothstep(-0.01, 0.02, ds))); }

// ---------------------------------------------------------------- letters: round-ended strokes, cap height 1
float ring(vec2 p, vec2 c, float r) { return abs(length(p - c) - r); }
float lD(vec2 p) { float d = min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), min(sdSeg(p, vec2(0.0, 1.0), vec2(0.22, 1.0)), sdSeg(p, vec2(0.0), vec2(0.22, 0.0))));
                   return p.x >= 0.22 ? min(d, ring(p, vec2(0.22, 0.5), 0.5)) : d; }
float lI(vec2 p) { return sdSeg(p, vec2(0.0), vec2(0.0, 1.0)); }
float lN(vec2 p) { return min(min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.0, 1.0), vec2(0.66, 0.0))), sdSeg(p, vec2(0.66, 0.0), vec2(0.66, 1.0))); }
float lK(vec2 p) { return min(min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.02, 0.4), vec2(0.6, 1.0))), sdSeg(p, vec2(0.2, 0.6), vec2(0.62, 0.0))); }
float lE(vec2 p) { return min(min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.0, 1.0), vec2(0.5, 1.0))), min(sdSeg(p, vec2(0.0, 0.5), vec2(0.42, 0.5)), sdSeg(p, vec2(0.0), vec2(0.5, 0.0)))); }
float lL(vec2 p) { return min(sdSeg(p, vec2(0.0), vec2(0.0, 1.0)), sdSeg(p, vec2(0.0), vec2(0.48, 0.0))); }
float ld(vec2 p) { return min(ring(p, vec2(0.29, 0.31), 0.29), sdSeg(p, vec2(0.58, 0.0), vec2(0.58, 1.0))); }
float lo(vec2 p) { return ring(p, vec2(0.3, 0.31), 0.3); }
float lf(vec2 p) {
  float d = min(sdSeg(p, vec2(0.14, 0.0), vec2(0.14, 0.74)), sdSeg(p, vec2(0.0, 0.6), vec2(0.36, 0.6)));
  if (p.y >= 0.74 && p.x <= 0.52) d = min(d, abs(length(p - vec2(0.36, 0.74)) - 0.22));
  return min(d, sdSeg(p, vec2(0.36, 0.96), vec2(0.46, 0.93)));
}
// Letter i hops on its own eighth of the bar, so they go in turn.
float hop(float i) {
  float ph = mod(barBeat() * 2.0 - i, 8.0);
  return (ph < 1.0 ? p_hop * 0.18 * sin(ph * PI) : 0.0) + p_trip * 0.07 * sin(u_beat * PI * 0.5 + i * 0.8);   // and a slow wave along the word
}
// DINKI DELL on one line and doof under it, both centred on x = 0, the caps' baseline at y.
float title(vec2 p, float y, float h) {
  vec2 q = (p - vec2(-3.74 * h, y)) / h;                               // DINKI DELL is 7.48 caps wide
  float d = lD(q - vec2(0.0, hop(0.0)));
  d = min(d, lI(q - vec2(1.08, hop(1.0))));
  d = min(d, lN(q - vec2(1.44, hop(2.0))));
  d = min(d, lK(q - vec2(2.46, hop(3.0))));
  d = min(d, lI(q - vec2(3.44, hop(4.0))));
  d = min(d, lD(q - vec2(4.3, hop(5.0))));
  d = min(d, lE(q - vec2(5.38, hop(6.0))));
  d = min(d, lL(q - vec2(6.24, hop(7.0))));
  d = min(d, lL(q - vec2(7.0, hop(0.0))));
  vec2 r = (p - vec2(-1.27 * h * 0.8, y - 1.25 * h)) / (h * 0.8);      // doof, smaller, 2.54 wide
  float e = ld(r - vec2(0.0, hop(1.0)));
  e = min(e, lo(r - vec2(0.72, hop(2.0))));
  e = min(e, lo(r - vec2(1.44, hop(3.0))));
  e = min(e, lf(r - vec2(2.16, hop(4.0))));
  return min(d * h, e * h * 0.8);
}

// ---------------------------------------------------------------- the three icons, each about radius 1
float rays(vec2 q, float pulse) {
  float a = atan(q.y, q.x + 1e-5), sec = TAU / 20.0, i = floor(a / sec + 0.5);
  vec2 r = rot(-i * sec) * q;
  float sway = 0.1 * p_trip * sin(i * 1.7 + u_beat * PI * 0.5);       // the rays undulate, a wave running round them
  return sdSeg(r, vec2(0.48, 0.0), vec2(0.86 + 0.1 * sin(i * 2.4) + sway + pulse, 0.0)) - 0.075;
}
float bee(vec2 q, float flap, out float wing) {
  float body = min(min(sdEll(q - vec2(0.0, 0.3), vec2(0.17, 0.16)), sdEll(q - vec2(0.0, 0.03), vec2(0.21, 0.2))), sdEll(q - vec2(0.0, -0.4), vec2(0.22, 0.36)));
  vec2 m = vec2(abs(q.x), q.y);
  body = min(body, sdSeg(m, vec2(0.06, 0.42), vec2(0.16, 0.66)) - 0.026);
  body = min(body, length(m - vec2(0.17, 0.68)) - 0.05);
  wing = min(sdEll(rot(-0.35) * (m - vec2(0.48, 0.18)), vec2(0.36, 0.28 * flap)), sdEll(rot(0.45) * (m - vec2(0.4, -0.3)), vec2(0.25, 0.2 * flap)));
  return body;
}
float glyphs(vec2 q) {
  float d = min(abs(length(q - vec2(-0.45, 0.32)) - 0.17), length(q - vec2(-0.45, 0.32)) - 0.05);
  d = min(d, sdSeg(q, vec2(0.05, 0.45), vec2(0.55, 0.45)));
  d = min(d, abs(sdBox(q - vec2(0.3, 0.05), vec2(0.13, 0.13), 0.03)));
  d = min(d, sdSeg(q, vec2(-0.65, -0.05), vec2(-0.2, -0.05)));
  vec2 s = q - vec2(-0.35, -0.45);
  for (int i = 0; i < 3; i++) { vec2 r = rot(float(i) * PI / 3.0) * s; d = min(d, sdSeg(r, vec2(-0.18, 0.0), vec2(0.18, 0.0))); }
  d = min(d, min(length(q - vec2(0.18, -0.45)), length(q - vec2(0.45, -0.45))) - 0.05);
  d = min(d, sdSeg(q, vec2(0.18, -0.45), vec2(0.45, -0.45)));
  return d - 0.03;
}

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0); p.y = -p.y;
  float k = kick() * p_beat, dr = dropArc() * p_drop;
  float hs = p_follow > 0.5 ? u_hue - 0.17 : 0.0;

  // Palettes: 0 the cover (lime), 1 night, 2 pink, 3 sky.
  vec3 BG = vec3(0.882, 0.918, 0.482), INK = vec3(0.62, 0.56, 0.76);
  vec3 PEACH = vec3(0.99, 0.79, 0.6), MAROON = vec3(0.36, 0.11, 0.17), GOLD = vec3(0.98, 0.76, 0.33), IRIS = vec3(0.3, 0.68, 0.88);
  if (p_pal > 0.5 && p_pal < 1.5) { BG = vec3(0.08, 0.06, 0.16); INK = vec3(1.0, 0.45, 0.75); PEACH = vec3(1.0, 0.86, 0.45); }
  else if (p_pal > 1.5 && p_pal < 2.5) BG = vec3(0.98, 0.72, 0.78);
  else if (p_pal > 2.5) BG = vec3(0.55, 0.85, 0.95);
  if (hs != 0.0) { vec3 o = hsv(fract(hs), 0.3, 1.0); BG *= o / max(max(o.r, o.g), o.b); }
  float cyc = p_cycle * u_beat / 64.0;                                  // the palette rolling round the wheel
  BG = rotHue(BG, cyc); INK = rotHue(INK, cyc); PEACH = rotHue(PEACH, cyc * 0.5); GOLD = rotHue(GOLD, cyc * 0.5);

  // The icon, centred where a triangle is widest for its height (about a third up from the base).
  float R = 0.235 * p_size * (1.0 + 0.04 * k + 0.12 * dr);
  vec2 c = vec2(0.0, -0.02 + p_cy);
  vec3 col = spiral(BG, mix(BG, INK, 0.45), p - c, p_trip) * (1.0 + 0.08 * dr);   // lime and lilac on the cover
  // Clean rings rippling out from the middle on the beat (the shapes' own outlines came out lumpy).
  col = mix(col, INK, clamp(echo(length(p - c) - R * 1.05) * p_echo, 0.0, 1.0) * 0.8);
  vec2 e = (melt(p, p_melt) - c) / R;
  // Which icon: 1 the eye, 2 the bee, 3 the disc, or 0 all three in turn, every so many bars. At each
  // change it turns like a coin over a beat, edge on at the downbeat, and comes round as the next one.
  float show = floor(p_show + 0.5) - 1.0;
  if (show < 0.0) {
    float per = 4.0 * max(1.0, p_every), bb = barBeat();
    float n = floor(bb / per), ph = bb - n * per;
    show = mod(n, 3.0);
    // Closing over the half beat before the 1, edge on at the 1, opening as the next one over the half beat after.
    float sx = ph < 0.5 ? sin(PI * ph) : ph > per - 0.5 ? sin(PI * (per - ph)) : 1.0;
    e.x /= max(sx, 0.03);
  }
  if (dot(e, e) < 2.2) {
    if (show < 0.5) {                                                  // the eye in its sunburst
      vec2 er = rot(u_beat * p_spin * TAU / 64.0) * e;
      float pulse = 0.08 * k + 0.25 * dr;
      col = shade(col, rays(rot(u_beat * p_spin * TAU / 64.0) * (e - vec2(0.07, -0.1)), pulse) * R);
      col = clay(col, PEACH, rays(er, pulse) * R, rays(er + LGT * 0.06, pulse) * R);
      vec2 A = vec2(0.0, 0.44), B = vec2(0.52, -0.38), C = vec2(-0.52, -0.38);
      col = shade(col, sdTri(e - vec2(0.05, -0.08), A, B, C) * R);
      col = clay(col, PEACH * 1.03, sdTri(e, A, B, C) * R - 0.004, sdTri(e + LGT * 0.06, A, B, C) * R - 0.004);
      float blink = smoothstep(0.92, 1.0, fract(u_beat / 16.0)) * (1.0 - smoothstep(0.98, 1.0, fract(u_beat / 16.0)));
      float open = max(0.0, 1.0 - 2.0 * blink + 0.25 * dr);
      vec2 ey = e - vec2(0.0, -0.07);
      float white = sdEll(ey, vec2(0.31, 0.18 * open + 0.001)) * R;
      col = clay(col, vec3(0.98, 0.97, 0.94), white, sdEll(ey + LGT * 0.06, vec2(0.31, 0.18 * open + 0.001)) * R);
      if (white < 0.0) {
        vec2 look = 0.06 * vec2(sin(u_beat * 0.37), 0.4 * sin(u_beat * 0.23)) * (1.0 - dr);
        vec2 il = ey - look;                                             // the iris: a rainbow spiral turning on the trip
        vec3 ic = mix(IRIS, hsv(atan(il.y, il.x + 1e-5) / TAU + length(il) * 6.0 - u_beat * 0.25, 0.7, 1.0), 0.75 * p_trip);
        col = mix(col, ic * (0.8 + 0.3 * clamp(1.0 - length(il - vec2(-0.04, 0.04)) * 6.0, 0.0, 1.0)), fill((length(il) - 0.145) * R));
        col = mix(col, vec3(0.08, 0.1, 0.14), fill((length(ey - look) - 0.068 * (1.0 - 0.3 * dr)) * R));
        col = mix(col, vec3(1.0), fill((length(ey - look - vec2(-0.05, 0.05)) - 0.026) * R));
      }
    } else if (show < 1.5) {                                           // the bee, flapping on the kick
      float flap = 1.0 - 0.45 * exp(-10.0 * u_frac) * step(0.01, p_beat);
      float w, wl, ws;
      float bd = bee(e, flap, w), bdl = bee(e + LGT * 0.05, flap, wl), bds = bee(e - vec2(0.06, -0.09), flap, ws);
      col = shade(col, min(bds, ws) * R);
      vec2 g = fract(e * 26.0) - 0.5;
      vec3 quilt = MAROON * (0.92 + 0.16 * (1.0 - smoothstep(0.15, 0.35, length(g))));
      col = clay(col, quilt * 1.08, w * R, wl * R);
      col = clay(col, quilt, bd * R, bdl * R);
    } else {                                                           // the golden disc, turning slowly
      float dd = (length(e) - 0.92) * R;
      col = shade(col, (length(e - vec2(0.06, -0.09)) - 0.92) * R);
      col = clay(col, GOLD, dd, (length(e + LGT * 0.06) - 0.92) * R);
      if (dd < 0.0) {
        vec2 r3 = rot(u_beat * p_spin * TAU / 128.0) * e;
        float gd = glyphs(r3 * 1.15), gdl = glyphs((r3 + LGT * 0.04) * 1.15);
        float lit = clamp((gdl - gd) / 0.025, -1.0, 1.0);
        float edge = fill(gd * R) * (1.0 - smoothstep(0.0, 0.05, -gd));
        col *= 1.0 + 0.25 * lit * edge + 0.1 * k * fill(gd * R);
        col = mix(col, hsv(length(r3) * 2.0 - u_beat * 0.25, 0.6, 1.0), fill(gd * R) * 0.6 * p_trip);   // the glyphs glow in rainbow
      }
    }
  }

  // DINKI DELL and doof along the bottom, the widest part of a triangle.
  if (p_text > 0.5) {
    float h = 0.052 * p_size, y = -0.345 + p_cy;
    if (abs(p.x) < 4.3 * h && p.y > y - 1.6 * h && p.y < y + 1.4 * h) {
      float w = 0.009 * p_size;
      float d = title(p, y, h) - w, dl = title(p + LGT * 0.004, y, h) - w;
      col = mix(col, INK * (1.0 + 0.15 * clamp((dl - d) / 0.002, -1.0, 1.0)), fill(d));
    }
  }
  return clamp(col * p_bright, 0.0, 1.0);
}
