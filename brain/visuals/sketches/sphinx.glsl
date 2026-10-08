// Sphinx: the Sphinx face on, as a bust, centred for a triangle surface, for the Dinki Dell doof. Its
// headdress flares out to the shoulders like a pyramid, striped gold and blue, with the cobra on the
// brow, the false beard and a broad striped collar along the bottom; a sun sits behind its head.
// On the beat a ripple of light runs down the stripes and the eyes look round and blink; through a
// build the eyes glow red, and on the drop they blaze with laser starbursts.
// Simple shapes on a flat sky, nothing near the sides, so a trimmed triangle still shows it all.
// Params are p_* uniforms; ranges and defaults are in sphinx.json.
uniform float p_size, p_cy, p_sun, p_stripes, p_ripple, p_look, p_laser, p_beat, p_drop, p_pal, p_follow, p_bright,
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
float smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }
float fill(float d) { return 1.0 - smoothstep(-u_px, u_px, d); }

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

// The headdress: a dome over the head and the cloth flaring down to the shoulders.
float nemes(vec2 p) {
  float d = sdEll(p - vec2(0.0, 0.15), vec2(0.17, 0.13));
  d = smin(d, sdTri(p, vec2(-0.16, 0.13), vec2(0.16, 0.13), vec2(0.27, -0.25)), 0.02);
  d = smin(d, sdTri(p, vec2(-0.16, 0.13), vec2(0.27, -0.25), vec2(-0.27, -0.25)), 0.02);
  return d;
}
float face(vec2 p) { return smin(sdEll(p - vec2(0.0, 0.03), vec2(0.1, 0.13)), sdEll(p - vec2(0.0, -0.06), vec2(0.075, 0.06)), 0.03); }
float beard(vec2 p) { return sdBox(p - vec2(0.0, -0.165), vec2(0.026, 0.06), 0.018); }
float collar(vec2 p) { return max(sdEll(p - vec2(0.0, -0.3), vec2(0.3, 0.13)), -(p.y + 0.3)); }   // the top half of an oval

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0); p.y = -p.y;
  float k = kick() * p_beat, dr = dropArc() * p_drop;
  float build = clamp(u_progress, 0.0, 1.0) * step(3.5, u_scene) * step(u_scene, 5.5);
  vec2 q = (p - vec2(0.0, -0.01 + p_cy)) / p_size;
  float hs = p_follow > 0.5 ? u_hue - 0.1 : 0.0;

  // Palettes: 0 desert, 1 the cover (lime), 2 night, 3 pink.
  vec3 SKY = vec3(0.55, 0.82, 0.96), SKY2 = vec3(0.99, 0.84, 0.62), SUN = vec3(1.0, 0.88, 0.45);
  vec3 STONE = vec3(0.97, 0.76, 0.5), GOLD = vec3(0.99, 0.78, 0.3), LAPIS = vec3(0.12, 0.36, 0.78), RED = vec3(0.86, 0.3, 0.25);
  vec3 LASER = vec3(1.0, 0.15, 0.25);
  if (p_pal > 0.5 && p_pal < 1.5) { SKY = vec3(0.882, 0.918, 0.482); SKY2 = vec3(0.9, 0.93, 0.56); SUN = vec3(0.99, 0.79, 0.6); STONE = vec3(0.99, 0.8, 0.62); LAPIS = vec3(0.62, 0.56, 0.76); RED = vec3(0.0, 0.62, 0.84); }
  else if (p_pal > 1.5 && p_pal < 2.5) { SKY = vec3(0.08, 0.05, 0.2); SKY2 = vec3(0.3, 0.1, 0.42); SUN = vec3(1.0, 0.45, 0.75); STONE = vec3(0.35, 0.85, 0.9); GOLD = vec3(1.0, 0.85, 0.35); LAPIS = vec3(0.55, 0.2, 0.9); RED = vec3(1.0, 0.4, 0.75); LASER = vec3(0.3, 1.0, 0.5); }
  else if (p_pal > 2.5) { SKY = vec3(0.99, 0.75, 0.82); SKY2 = vec3(1.0, 0.86, 0.7); SUN = vec3(1.0, 0.95, 0.6); STONE = vec3(0.99, 0.84, 0.72); LAPIS = vec3(0.9, 0.35, 0.55); RED = vec3(0.3, 0.6, 0.95); }
  if (hs != 0.0) { vec3 o = hsv(fract(hs), 0.3, 1.0); o /= max(max(o.r, o.g), o.b); SKY *= o; SKY2 *= o; }
  float cyc = p_cycle * u_beat / 64.0;                                  // the palette rolling round the wheel
  SKY = rotHue(SKY, cyc); SKY2 = rotHue(SKY2, cyc); SUN = rotHue(SUN, cyc); LAPIS = rotHue(LAPIS, cyc); RED = rotHue(RED, cyc);

  vec3 sky = mix(SKY2, SKY, smoothstep(-0.4, 0.4, q.y));
  vec3 col = spiral(sky, mix(sky, SUN, 0.55), q - vec2(0.0, 0.08), p_trip) * (1.0 + 0.1 * dr);   // a spiral turning out from behind the head
  // ---- the sun behind the head
  if (p_sun > 0.5) {
    vec2 sc = vec2(0.0, 0.1);
    float sr = 0.25 + 0.006 * k + 0.02 * dr;
    if (length(q - sc) < sr + 0.03) col = clay(col, SUN, length(q - sc) - sr, length(q - sc + LGT * 0.01) - sr);
  }
  if ((abs(q.x) > 0.36 || q.y < -0.45 || q.y > 0.34) && dr < 0.01) return clamp(col * p_bright, 0.0, 1.0);

  // ---- the headdress: stripes across, a ripple of light running down them on the beat
  col = mix(col, GOLD * 1.1, clamp(echo(nemes(q)) * p_echo, 0.0, 1.0));   // the headdress rippling out on the beat
  q = melt(q, p_melt);
  float nd = nemes(q);
  col = shade(col, nemes(q - vec2(0.03, -0.02)));
  // The stripes flow down the cloth at a steady speed (a speed a knob can move would jump them along).
  float sy = (q.y + u_beat * 0.03 * step(0.001, p_trip)) * p_stripes * 2.0;
  vec3 band2 = mix(LAPIS, hsv(floor(sy) * 0.13 - u_beat / 32.0, 0.75, 0.95), 0.8 * p_trip);   // and turn rainbow
  vec3 cloth = mix(GOLD, band2, step(0.5, fract(sy)));
  float rip = p_ripple * exp(-abs(fract(-q.y * 1.6 - u_frac) - 0.5) * 10.0) * (0.4 + 0.6 * k);
  col = clay(col, cloth * (1.0 + 0.45 * rip), nd, nemes(q + LGT * 0.008));
  // A gold band across the brow.
  col = mix(col, GOLD * 1.05, fill(sdBox(q - vec2(0.0, 0.135), vec2(0.115, 0.012), 0.006)));

  // ---- the broad collar along the bottom: bands of colour
  float cd = collar(q);
  col = shade(col, collar(q - vec2(0.02, -0.015)));
  float rr = length((q - vec2(0.0, -0.3)) / vec2(0.3, 0.13));
  vec3 band = rr < 0.45 ? STONE : rr < 0.62 ? LAPIS : rr < 0.78 ? GOLD : rr < 0.9 ? RED : GOLD;
  col = clay(col, band, cd, collar(q + LGT * 0.008));

  // ---- the face, the beard, the cobra on the brow
  col = shade(col, face(q - vec2(0.02, -0.015)));
  col = clay(col, STONE, face(q), face(q + LGT * 0.008));
  col = clay(col, mix(GOLD, LAPIS, step(0.5, fract(q.y * 40.0))), beard(q), beard(q + LGT * 0.008));
  float cobra = smin(sdEll(q - vec2(0.0, 0.155), vec2(0.016, 0.028)), sdEll(q - vec2(0.0, 0.185), vec2(0.022, 0.014)), 0.01);
  col = clay(col, GOLD * 1.08, cobra, smin(sdEll(q + LGT * 0.006 - vec2(0.0, 0.155), vec2(0.016, 0.028)), sdEll(q + LGT * 0.006 - vec2(0.0, 0.185), vec2(0.022, 0.014)), 0.01));
  // Nose and mouth, in a few strokes.
  col = mix(col, STONE * 0.78, fill(sdSeg(q, vec2(0.0, 0.04), vec2(0.0, -0.005)) - 0.004));
  col = mix(col, STONE * 0.8, fill(sdSeg(q, vec2(-0.012, -0.012), vec2(0.012, -0.012)) - 0.006));
  col = mix(col, STONE * 0.7, fill(abs(sdEll(q - vec2(0.0, -0.055), vec2(0.028, 0.008))) - 0.003));

  // ---- the eyes: almonds lined with kohl, looking round, blinking; red through a build, blazing on the drop
  float blink = smoothstep(0.93, 1.0, fract(u_beat / 16.0)) * (1.0 - smoothstep(0.98, 1.0, fract(u_beat / 16.0)));
  float open = max(0.05, 1.0 - 2.0 * blink);
  vec2 look = vec2(0.008 * sin(u_beat * 0.37), 0.003 * sin(u_beat * 0.23)) * p_look * (1.0 - dr);
  for (int i = 0; i < 2; i++) {
    float sx = i == 0 ? -1.0 : 1.0;
    vec2 e = q - vec2(0.042 * sx, 0.07);
    vec2 em = vec2(e.x * sx, e.y);                                      // mirrored so the kohl runs outward on both
    float ed = sdEll(em, vec2(0.026, 0.012 * open));
    col = mix(col, vec3(0.1, 0.08, 0.12), fill(min(abs(ed) - 0.003, sdSeg(em, vec2(0.022, 0.002), vec2(0.045, 0.008)) - 0.003)));
    col = mix(col, vec3(0.1, 0.08, 0.12), fill(sdSeg(em, vec2(-0.025, 0.026), vec2(0.03, 0.03)) - 0.003));   // the brow
    col = mix(col, vec3(0.99, 0.97, 0.92), fill(ed));
    vec2 il = e - look;                                                // the iris: a rainbow spiral on the trip, red in a build
    vec3 ic = mix(vec3(0.15, 0.1, 0.08), hsv(atan(il.y, il.x + 1e-5) / TAU + length(il) * 60.0 - u_beat * 0.5, 0.8, 1.0), 0.8 * p_trip);
    if (ed < 0.0) col = mix(col, mix(ic, LASER, max(build, dr)), fill(length(il) - 0.009));
    col += LASER * exp(-length(e) / 0.018) * (0.7 * build + 1.4 * dr) * p_laser;
    // The drop: a starburst of laser lines out of each eye, turning, flickering on the 16ths.
    if (dr > 0.01 && p_laser > 0.0) {
      float a = atan(e.y, e.x + 1e-5) + u_beat * 0.3 * sx, n = 8.0, sec = TAU / n;
      float j = floor(a / sec + 0.5);
      vec2 r = vec2(cos(a - j * sec), sin(a - j * sec)) * length(e);
      float beam = (exp(-abs(r.y) / 0.004) * 1.4 + exp(-abs(r.y) / 0.02) * 0.35) * smoothstep(0.02, 0.05, r.x) * exp(-r.x / 0.6);
      col = mix(col, vec3(1.0), clamp(beam * dr * p_laser, 0.0, 1.0) * 0.5);
      col += LASER * beam * dr * p_laser * (0.75 + 0.25 * step(0.5, fract(u_beat * 4.0)));
    }
  }
  return clamp(col * p_bright, 0.0, 1.0);
}
