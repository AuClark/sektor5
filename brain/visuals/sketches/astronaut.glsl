// Astronaut: a chunky clay astronaut floating in the middle of a flat bright sky, centred for a
// triangle surface, for the Dinki Dell doof. A few stars twinkle on the beat, one arm waves and the
// chest buttons light in turn; the visor reflects a studio spotlight (it was all filmed on a set).
// On the drop the astronaut does a full flip, the visor shows the all-seeing eye and the stars burst.
// Nothing sits near the sides, so a trimmed triangle still shows it all.
// Params are p_* uniforms; ranges and defaults are in astronaut.json.
uniform float p_size, p_cy, p_drift, p_wave, p_stars, p_flip, p_beat, p_drop, p_pal, p_follow, p_bright,
              p_trip, p_echo, p_melt, p_spin, p_cycle;

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
  float r = length(p) + 1e-3, a = atan(p.y, p.x), lr = log(r);
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
  float fit = 0.72 * p_size;
  float hs = p_follow > 0.5 ? u_hue - 0.17 : 0.0;

  // Palettes: 0 the cover (lime), 1 space (navy, neon), 2 pink, 3 sky.
  vec3 BG = vec3(0.882, 0.918, 0.482), SUIT = vec3(0.97, 0.96, 0.93), PACK = vec3(0.86, 0.85, 0.82), STAR = vec3(1.0);
  vec3 VIS = vec3(0.12, 0.1, 0.25), VIS2 = vec3(0.45, 0.3, 0.75);
  if (p_pal > 0.5 && p_pal < 1.5) { BG = vec3(0.07, 0.06, 0.2); STAR = vec3(1.0, 0.95, 0.7); }
  else if (p_pal > 1.5 && p_pal < 2.5) BG = vec3(0.98, 0.72, 0.78);
  else if (p_pal > 2.5) BG = vec3(0.55, 0.85, 0.95);
  if (hs != 0.0) { vec3 o = hsv(fract(hs), 0.3, 1.0); BG *= o / max(max(o.r, o.g), o.b); }
  float cyc = p_cycle * u_beat / 64.0;                                  // the palette rolling round the wheel
  BG = rotHue(BG, cyc); VIS = rotHue(VIS, cyc); VIS2 = rotHue(VIS2, cyc);
  vec3 B2 = p_pal > 0.5 && p_pal < 1.5 ? vec3(0.25, 0.1, 0.4) : mix(BG, vec3(0.62, 0.56, 0.76), 0.45);
  vec3 col = spiral(BG, rotHue(B2, cyc), p - vec2(0.0, -0.085), p_trip) * (1.0 + 0.08 * dr);   // a spiral turning out from behind

  // ---- hyperspace: star streaks flowing out from the astronaut, faster on the trip, rushing on the drop
  if (p_stars > 0.0) {
    vec2 s0 = p - vec2(0.0, -0.085);
    float r = length(s0), ang = atan(s0.y, s0.x);
    vec2 g = vec2(ang / TAU * 36.0, log(r + 0.02) * 6.0 - u_beat * (0.4 + 1.2 * p_trip) * (1.0 + 2.0 * dr));
    vec2 cell = floor(g), f = fract(g) - 0.5;
    float hh = hash(cell);
    if (hh > 0.72) {
      float tw = 0.5 + 0.5 * sin(u_beat * PI * 0.5 + hh * 20.0);
      float streak = (1.0 - smoothstep(0.0, 0.1, abs(f.x))) * (1.0 - smoothstep(0.0, 0.25 + 0.35 * p_trip, abs(f.y)));
      col = mix(col, STAR, clamp(streak * (0.5 + 0.5 * tw + 0.6 * k) * p_stars, 0.0, 1.0) * smoothstep(0.06, 0.16, r));
    }
  }
  // ---- where the astronaut is: drifting, tilting, flipping once on the drop
  vec2 c = vec2(-0.03 * p_size, -0.085 + p_cy) + p_drift * vec2(0.02 * sin(u_beat * PI / 16.0), 0.02 * sin(u_beat * PI / 8.0));
  float flip = p_flip * (abs(u_scene - 7.0) < 0.5 ? smoothstep(0.0, 4.0, u_since) * TAU : 0.0);
  float tilt = p_drift * 0.12 * sin(u_beat * PI / 16.0 + 1.0) + flip + u_beat * p_spin * TAU / 64.0;
  vec2 a = melt(rot(-tilt) * (p - c) / fit, p_melt);
  vec2 al = melt(rot(-tilt) * (p - c + LGT * 0.008 * fit) / fit, p_melt);
  vec2 as = melt(rot(-tilt) * (p - c - vec2(0.025, -0.02) * fit) / fit, p_melt);
  float wave = p_wave * (0.5 + 0.5 * sin(u_beat * PI));               // up and down once every two beats

  // ---- the astronaut
  if (dot(a, a) < 0.6) {
    col = mix(col, vec3(1.0), clamp(echo(min(min(pack(a), suit(a, wave)), helmet(a)) * fit) * p_echo, 0.0, 1.0));   // outlines rippling out of it
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
      vc = mix(vc, hsv(atan(v.y, v.x) / TAU * 2.0 + length(v) * 10.0 - u_beat * 0.5, 0.65, 0.95), 0.55 * p_trip);   // a swirl of colour in the glass
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
