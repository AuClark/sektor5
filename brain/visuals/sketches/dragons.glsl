// Dragons: a duel between a red fire dragon and a blue ice dragon. Two long eastern serpents
// (heads with snouts, jaws, horns, manes, whiskers and glowing eyes; scaled bodies with a
// finned spine, pale belly plates, little clawed legs and tail tufts) swirl round each
// other in a tilted orbit, drawn as distance fields to a polyline that follows each
// head's path. Every four bars: the red breathes fire, the blue breathes ice, a bar of
// swirling, then both at once, the blasts clashing in the middle in steam and sparks,
// pulsing on the kick. Through a BUILD the orbit tightens and quickens and the breaths
// come twice as often; on the DROP (and every few bars on its own) they curl into a heart
// and kiss nose to nose in a burst of purple light. BREAKDOWNs go slow and dreamy.
// Params are p_* uniforms; ranges and defaults are in dragons.json.
// Its kiss cycle runs on u_cbeat, so the kiss ("climax" in the JSON) can land on the drop.
uniform float p_orbit, p_radius, p_tilt, p_wave, p_size, p_build, p_thick, p_length, p_legs,
              p_whisk, p_rhue, p_bhue, p_fire, p_reach, p_clash, p_every, p_hearts, p_glow,
              p_stars, p_bright, p_punch, p_droplock;

#define PI 3.1415927
#define TAU 6.2831853
#define NSEG 30

float g_t, g_kz, g_rx, g_ry, g_amp, g_len, g_th, g_L, g_px, g_lw;

mat2 R(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }
float sdE(vec2 p, vec2 r) { return (length(p / r) - 1.0) * min(r.x, r.y); }
float sdTC(vec2 p, vec2 a, vec2 b, float r0, float r1) {       // tapered capsule
  vec2 pa = p - a, ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h) - mix(r0, r1, h);
}
float smin(float a, float b, float k) {
  float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}
float vn(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
// Heart (Inigo Quilez): tip at the origin, y up, about 1 tall.
float sdHeart(vec2 p) {
  p.x = abs(p.x);
  if (p.y + p.x > 1.0) return length(p - vec2(0.25, 0.75)) - 0.35355;
  vec2 a = p - vec2(0.0, 1.0), b = p - 0.5 * max(p.x + p.y, 0.0);
  return sqrt(min(dot(a, a), dot(b, b))) * sign(p.x - p.y);
}
vec2 turn(vec2 a, vec2 b, float t) {                           // unit a towards unit b by angle
  float aa = atan(a.y, a.x), ab = atan(b.y, b.x);
  float x = aa + (mod(ab - aa + PI, TAU) - PI) * t;
  return vec2(cos(x), sin(x));
}

// Filled shape with a dark outline, in units where a pixel is px.
void ink(inout vec3 col, float d, vec3 c, float px, float lw) {
  col = mix(col, c * 0.06, clamp(0.5 - (d - lw) / px, 0.0, 1.0));
  col = mix(col, c, clamp(0.5 - d / px, 0.0, 1.0));
}
void paint(inout vec3 col, float d, vec3 c, float px) { col = mix(col, c, clamp(0.5 - d / px, 0.0, 1.0)); }

// ---- The bodies: a point s (0 head .. 1 tail) along a dragon, as (xy, depth z: + is far).
vec3 orbitPt(float side, float s) {
  float a = g_t + (side > 0.0 ? PI : 0.0) - s * g_len;
  float r = 1.0 + 0.14 * sin(2.0 * a + side * 1.3);
  r += g_amp * sin(s * 13.0 - u_beat * PI) * smoothstep(0.0, 0.25, s);
  return vec3(cos(a) * g_rx * r, sin(a) * g_ry * r, sin(a));
}
vec2 heartPt(float side, float s) {                    // the kiss pose: each one half a heart
  float t = mix(0.72, 3.0, s), st = sin(t);
  float x = 16.0 * st * st * st - 4.587, y = 13.0 * cos(t) - 5.0 * cos(2.0 * t) - 2.0 * cos(3.0 * t) - cos(4.0 * t);
  return vec2(side * (x * 0.017 + 0.9 * g_L), y * 0.017 - 0.0);
}
vec3 bp(float side, float s) {
  vec3 o = orbitPt(side, s);
  float w = smoothstep(0.0, 1.0, clamp(g_kz * 1.7 - s * 0.7, 0.0, 1.0));
  return vec3(mix(o.xy, heartPt(side, s), w), o.z * (1.0 - w));
}
float radiusAt(float s) {
  return g_th * mix(1.0, 0.14, smoothstep(0.08, 1.0, s)) * mix(0.7, 1.0, smoothstep(0.0, 0.08, s));
}
// Nearest point on a dragon's body: (distance, s, v across -1..1 with + on the finned
// outer side, depth).
vec4 bodyQ(vec2 p, float side) {
  // The points along the body are the same for every pixel, so they're stepped along, not worked out
  // afresh: each of orbitPt's angles moves by a fixed amount from one point to the next, so the next
  // point is the last one turned by that much (complex multiplication), no sin or cos per segment.
  // Same curve as bp(); the kiss pose is only mixed in while there is a kiss.
  float ds = 1.0 / float(NSEG);
  float a0 = g_t + (side > 0.0 ? PI : 0.0);
  vec2 ea = vec2(cos(a0), sin(a0)), da = vec2(cos(g_len * ds), -sin(g_len * ds));                  // the angle a
  vec2 e2 = vec2(cos(2.0 * a0 + side * 1.3), sin(2.0 * a0 + side * 1.3)), d2 = vec2(da.x * da.x - da.y * da.y, 2.0 * da.x * da.y);   // 2a
  vec2 ew = vec2(cos(-u_beat * PI), sin(-u_beat * PI)), dw = vec2(cos(13.0 * ds), sin(13.0 * ds));  // the body's wave
  bool kiss = g_kz > 0.0;
  vec3 a = bp(side, 0.0);
  vec4 res = vec4(1e5, 0.0, 0.0, 0.0);
  for (int i = 1; i <= NSEG; i++) {
    ea = vec2(ea.x * da.x - ea.y * da.y, ea.x * da.y + ea.y * da.x);
    e2 = vec2(e2.x * d2.x - e2.y * d2.y, e2.x * d2.y + e2.y * d2.x);
    ew = vec2(ew.x * dw.x - ew.y * dw.y, ew.x * dw.y + ew.y * dw.x);
    float si = float(i) * ds;
    float rr = 1.0 + 0.14 * e2.y + g_amp * ew.y * smoothstep(0.0, 0.25, si);
    vec3 b = vec3(ea.x * g_rx * rr, ea.y * g_ry * rr, ea.y);
    if (kiss) {
      float w = smoothstep(0.0, 1.0, clamp(g_kz * 1.7 - si * 0.7, 0.0, 1.0));
      b = vec3(mix(b.xy, heartPt(side, si), w), b.z * (1.0 - w));
    }
    vec2 pa = p - a.xy, ba = b.xy - a.xy;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    vec2 c = pa - ba * h;
    float s = (float(i) - 1.0 + h) * ds;
    float z = mix(a.z, b.z, h);
    float r = radiusAt(s) * (1.0 + 0.15 * z * -1.0);
    float d = length(c) - r;
    if (d < res.x) {
      vec2 nl = vec2(-ba.y, ba.x);
      float outs = dot(nl, a.xy) >= 0.0 ? 1.0 : -1.0;
      float sg = (ba.x * c.y - ba.y * c.x) >= 0.0 ? 1.0 : -1.0;
      res = vec4(d, s, sg * outs * length(c) / r, z);
    }
    a = b;
  }
  return res;
}

void drawBody(inout vec3 col, vec4 q, vec3 base, vec3 belly, vec3 hot, float shimmer) {
  float d = q.x, s = q.y, v = q.z;
  if (d > 0.08) return;
  float r = radiusAt(s);
  float near = -q.w;
  // Dorsal fins on the outer side, swept back.
  float f = fract(s * 22.0);
  float sp = clamp(min(f / 0.3, (1.0 - f) / 0.7), 0.0, 1.0);
  if (v > 0.0) ink(col, d - r * (0.85 * sp + 0.08) * (1.0 - 0.5 * s), hot * (0.7 + 0.3 * sp) * (0.8 + 0.2 * near), g_px, g_lw);
  float vv = clamp(v, -1.0, 1.0);
  float cyl = sqrt(1.0 - vv * vv);
  vec3 c = base * (0.4 + 0.6 * cyl);
  // Scales: offset rows of arcs.
  vec2 g = vec2(s * 75.0 - u_beat * 0.0, vv * 2.4 + 3.0);
  g.x += 0.5 * mod(floor(g.y), 2.0);
  vec2 fq = fract(g) - vec2(0.5, 0.0);
  float sc = length(fq * vec2(1.0, 1.15));
  c *= 1.0 - 0.5 * smoothstep(0.38, 0.52, sc);
  c += hot * 0.22 * (1.0 - smoothstep(0.0, 0.45, sc)) * cyl * shimmer;
  // Belly plates.
  float bel = 1.0 - smoothstep(-0.45, -0.2, vv);
  vec3 bc = belly * (0.5 + 0.5 * cyl) * (0.7 + 0.3 * step(0.18, fract(s * 48.0)));
  c = mix(c, bc, bel);
  c += hot * pow(abs(vv), 6.0) * 0.5;                  // hot rim
  c *= 0.75 + 0.25 * near;
  ink(col, d, c, g_px, g_lw);
}

void drawLimbs(inout vec3 col, vec2 p, float side, vec3 base, vec3 hot, vec3 horn) {
  // Two legs on the belly side, paddling on the beat.
  for (int i = 0; i < 2; i++) {
    if (p_legs < 0.5) break;
    float s = i == 0 ? 0.2 : 0.58;
    vec3 a = bp(side, s), b = bp(side, s + 0.03);
    vec2 t = normalize(a.xy - b.xy + 1e-5);
    vec2 n = vec2(-t.y, t.x);
    if (dot(n, a.xy) > 0.0) n = -n;                      // belly side: inwards
    float r = radiusAt(s);
    float sw = sin(u_beat * PI + float(i) * 1.7 + side);
    vec2 knee = a.xy + n * r * 1.5 + t * r * (0.5 + 0.4 * sw);
    vec2 foot = knee + n * r * 0.6 - t * r * (1.0 - 0.5 * sw);
    if (length(p - a.xy) > r * 4.5) continue;
    ink(col, sdTC(p, a.xy, knee, r * 0.55, r * 0.38), base * 0.8, g_px, g_lw);
    ink(col, sdTC(p, knee, foot, r * 0.38, r * 0.28), base * 0.8, g_px, g_lw);
    for (int j = 0; j < 3; j++) {
      vec2 cd = R((float(j) - 1.0) * 0.6) * normalize(foot - knee);
      ink(col, sdTC(p, foot, foot + cd * r * 0.75, r * 0.14, r * 0.02), horn, g_px, g_lw * 0.7);
    }
  }
  // Tail tuft.
  vec3 tp = bp(side, 1.0), tq = bp(side, 0.95);
  vec2 t = normalize(tp.xy - tq.xy + 1e-5);
  if (length(p - tp.xy) < 0.2) {
    float tw = 0.3 * sin(u_beat * PI * 0.5 + side);
    for (int j = 0; j < 3; j++) {
      vec2 dd = R((float(j) - 1.0) * 0.55 + tw) * t;
      ink(col, sdTC(p, tp.xy - t * 0.01, tp.xy + dd * (0.09 + 0.03 * float(j == 1)), 0.02, 0.0), hot, g_px, g_lw);
    }
  }
}

void drawHead(inout vec3 col, vec2 p, vec2 o, vec2 dir, float hy, vec3 base, vec3 belly, vec3 hot,
              vec3 horn, vec3 eyeC, float open) {
  float L = g_L;
  vec2 rp = p - o;
  vec2 q = vec2(dot(rp, dir), dot(rp, vec2(-dir.y, dir.x)) * hy) / L;
  if (length(q - vec2(0.0, 0.1)) > 2.0) return;
  float px = g_px / L, lw = g_lw / L;
  float bt = u_beat * PI;
  // Whiskers.
  if (p_whisk > 0.5) {
    for (int w = 0; w < 2; w++) {
      float fw = float(w);
      vec2 a = w == 0 ? vec2(0.8, -0.02) : vec2(0.84, 0.13);
      float dw = 1e3;
      for (int j = 1; j < 6; j++) {
        float fj = float(j);
        vec2 b = a + vec2(-0.32, (w == 0 ? -0.1 : 0.08) + 0.1 * sin(fj * 1.3 - bt + fw));
        dw = min(dw, sdTC(q, a, b, 0.022 * (1.0 - fj / 6.0) + 0.005, 0.022 * (1.0 - (fj + 1.0) / 6.0) + 0.005));
        a = b;
      }
      paint(col, dw, hot, px);
    }
  }
  // Mane: flame or icicle spikes streaming back.
  for (int k = 0; k < 4; k++) {
    float fk = float(k);
    vec2 a = vec2(-0.12, 0.16 - 0.12 * fk);
    vec2 b = vec2(-0.75 - 0.1 * fk + 0.06 * sin(bt + fk), 0.42 - 0.26 * fk + 0.05 * sin(bt * 0.5 + fk));
    ink(col, sdTC(q, a, b, 0.1, 0.0), hot * (0.85 - 0.1 * fk), px, lw);
  }
  // Horns, swept back, with a branch.
  ink(col, sdTC(q, vec2(0.0, 0.22), vec2(-0.6, 0.66), 0.075, 0.015), horn, px, lw);
  ink(col, sdTC(q, vec2(-0.3, 0.43), vec2(-0.3, 0.75), 0.04, 0.008), horn, px, lw);
  ink(col, sdTC(q, vec2(0.12, 0.2), vec2(-0.3, 0.5), 0.05, 0.01), horn * 0.85, px, lw);
  // Fiery mouth inside when the jaw is open.
  float jaw = 0.1 + 0.42 * open;
  if (open > 0.02) paint(col, sdTC(q, vec2(0.12, -0.07), vec2(0.88, -0.1 - 0.4 * open), 0.08 * open, 0.12 * open), eyeC * 1.2, px);
  // Cheek frill.
  ink(col, sdE(R(0.5) * (q - vec2(-0.12, -0.1)), vec2(0.26, 0.08)), hot * 0.9, px, lw);
  // Lower jaw.
  vec2 jq = R(jaw) * (q - vec2(0.02, -0.08));
  ink(col, sdTC(jq, vec2(0.0, 0.0), vec2(0.74, -0.02), 0.12, 0.055), mix(base, belly, 0.4) * 0.9, px, lw);
  ink(col, sdTC(jq, vec2(0.62, 0.04), vec2(0.66, 0.15), 0.03, 0.0), vec3(1.0), px, lw * 0.6);
  // The open mouth, glowing with the breath, between the jaws.
  if (open > 0.02) {
    float mo = max(max(-q.y - 0.02, 0.06 - jq.y), max(0.06 - q.x, q.x - 0.8 + 0.25 * (1.0 - open)));
    mo = max(mo, -(-q.y - 0.02 + 0.0));
    paint(col, max(-q.y - 0.0, 0.0) > 0.0 ? max(0.06 - jq.y, max(0.08 - q.x, q.x - 0.82)) : 1.0, eyeC * 1.3, px);
    paint(col, max(-q.y - 0.0, 0.0) > 0.0 ? max(0.12 - jq.y, max(0.18 - q.x, q.x - 0.7)) : 1.0, vec3(1.0, 1.0, 0.95), px);
  }
  // Skull and snout.
  float sk = smin(sdE(q - vec2(0.02, 0.07), vec2(0.34, 0.25)), sdTC(q, vec2(0.15, 0.05), vec2(0.86, 0.02), 0.16, 0.12), 0.1);
  sk = smin(sk, length(q - vec2(0.88, 0.07)) - 0.11, 0.05);
  ink(col, sk, base, px, lw);
  paint(col, max(sk + 0.04, -(q.y - 0.1)), base * 1.25 + hot * 0.15, px);   // lit top of the snout
  // Fangs.
  ink(col, sdTC(q, vec2(0.72, -0.07), vec2(0.74, -0.2), 0.035, 0.0), vec3(1.0), px, lw * 0.6);
  ink(col, sdTC(q, vec2(0.5, -0.07), vec2(0.51, -0.17), 0.03, 0.0), vec3(1.0), px, lw * 0.6);
  // Brow, nostril, eye (shut during the kiss).
  ink(col, sdTC(q, vec2(0.1, 0.22), vec2(0.52, 0.17), 0.07, 0.03), base * 1.1, px, lw);
  paint(col, length(q - vec2(0.9, 0.1)) - 0.03, base * 0.08, px);
  vec2 eq = R(0.25) * (q - vec2(0.33, 0.09));
  float shut = 1.0 - 0.88 * smoothstep(0.4, 0.9, g_kz);
  float eye = sdE(eq, vec2(0.12, 0.065 * shut));
  ink(col, eye, eyeC, px, lw);
  paint(col, max(eye, sdE(eq - vec2(0.015, 0.0), vec2(0.022, 0.06 * shut))), vec3(0.02), px);
}

// A blast of fire (ice = 0) or ice (ice = 1) from mouth m along d, len long: additive light.
vec3 blast(vec2 p, vec2 m, vec2 d, float len, float ice, float hue, float amp) {
  if (len < 0.005) return vec3(0.0);
  vec2 rp = p - m;
  float a = dot(rp, d), b = dot(rp, vec2(-d.y, d.x));
  if (a < -0.05 || a > len + 0.15) return vec3(0.0);
  float w = 0.012 + (ice > 0.5 ? 0.17 : 0.24) * max(a, 0.0);
  float bt = u_beat;
  float n;
  if (ice > 0.5) n = 0.6 * vn(vec2(a * 6.0 - bt * 5.0, b / w * 4.0 + 3.0)) + 0.4 * vn(vec2(a * 20.0 - bt * 9.0, b / w * 9.0));
  else n = 0.65 * vn(vec2(a * 11.0 - bt * 8.0, b / w * 1.6 + 7.0)) + 0.35 * vn(vec2(a * 25.0 - bt * 14.0, b / w * 3.5 + 1.0));
  float core = 1.0 - abs(b) / w;
  float tip = 1.0 - smoothstep(len * 0.55, len, a + (n - 0.5) * 0.12);
  float heat = clamp(core + (n - 0.5) * 0.9, 0.0, 1.0) * tip * smoothstep(-0.03, 0.02, a);
  vec3 c;
  if (ice > 0.5) {
    c = hsv(hue - 0.07 * heat, 0.95 - 0.85 * heat * heat, 1.0) * heat * 1.6;
    // Frost sparkles streaming along the blast.
    vec2 g = vec2(a - bt * 0.35, b) * 70.0;
    vec2 gi = floor(g);
    float h = hash(gi);
    float sp = step(0.86, h) * (1.0 - smoothstep(0.05, 0.3, length(fract(g) - 0.5))) * step(abs(b), w * 1.1) * tip;
    c += vec3(0.85, 0.95, 1.0) * sp * 1.5;
  } else {
    c = hsv(hue + 0.13 * heat, 1.0 - 0.75 * heat * heat, 1.0) * heat * 1.7;
  }
  return c * amp;
}

vec3 content(vec2 uv) {
  // On a pyramid face (triangle, apex top centre) shrink into its incircle, centred low.
  float fit = min(u_aspect / 1.4, 1.0) * (u_tri > 0.5 ? 0.7 : 1.0);
  float S = max(p_size, 0.05) * fit;
  vec2 p = ((uv - 0.5) * vec2(u_aspect, 1.0) - vec2(0.0, u_tri > 0.5 ? 0.13 : 0.0)) / S;
  p.y = -p.y;
  g_px = u_px / S;
  g_lw = 1.3 * g_px;
  float k = kick();
  float sc = u_scene;
  bool build = sc > 3.5 && sc < 6.5;
  bool brk = abs(sc - 3.0) < 0.5;
  bool drop = abs(sc - 7.0) < 0.5;
  float prog = build ? clamp(u_sp, 0.0, 1.0) : 0.0;
  float tens = prog * p_build;

  // ── The kiss: every few bars on u_cbeat, and on the drop.
  float E = max(p_every, 16.0);
  float dB = (fract(u_cbeat / E) - (1.0 - 8.0 / E)) * E;
  float kz = smoothstep(-8.0, -1.0, dB) * (1.0 - smoothstep(4.0, 8.0, dB));
  float tk = dB;
  if (drop && p_droplock > 0.5 && u_since < 10.0) {
    float kd = 1.0 - smoothstep(6.0, 10.0, u_since);
    if (kd >= kz) { kz = kd; tk = u_since; }
  }
  g_kz = kz;

  // ── The dance.
  g_t = TAU * u_beat / (4.0 * max(p_orbit, 1.0)) + TAU * 1.5 * p_build * prog * prog;
  g_rx = 0.5 * p_radius * (1.0 - 0.25 * tens);
  g_ry = g_rx * p_tilt;
  g_amp = 0.1 * p_wave * (1.0 + tens) * (brk ? 0.5 : 1.0);
  g_len = p_length;
  g_th = 0.05 * p_thick * (1.0 + 0.06 * k * p_punch);
  g_L = g_th * 3.4;
  float L = g_L;

  vec3 redC = hsv(p_rhue, 0.92, 1.0), redB = hsv(p_rhue + 0.11, 0.65, 1.0), redH = hsv(p_rhue + 0.08, 0.9, 1.0);
  vec3 bluC = hsv(p_bhue, 0.85, 1.0), bluB = hsv(p_bhue - 0.08, 0.35, 1.0), bluH = hsv(p_bhue - 0.08, 0.55, 1.0);
  vec3 redHorn = vec3(1.0, 0.9, 0.65), bluHorn = vec3(0.85, 0.95, 1.0);
  vec3 redEye = vec3(1.0, 0.92, 0.45), bluEye = vec3(0.75, 1.0, 1.0);

  // ── Breaths, in four-beat slots (two-beat in the back half of a build): fire, ice, swirl, both.
  float bb = barBeat();
  float unit = prog > 0.5 ? 8.0 : 16.0;
  float slot = floor(mod(bb, unit) / (unit / 4.0));
  float tb = mod(bb, unit / 4.0) * 16.0 / unit;
  float env = smoothstep(0.0, 0.5, tb) * (1.0 - smoothstep(3.2, 3.9, tb));
  float bamt = p_fire * (1.0 - smoothstep(0.0, 0.3, kz)) * (brk ? 0.3 : 1.0) * (sc < 1.5 || sc > 7.5 ? 0.6 : 1.0);
  bool clash = slot > 2.5;
  float eR = (slot < 0.5 || clash) ? env * bamt : 0.0;
  float eB = ((slot > 0.5 && slot < 1.5) || clash) ? env * bamt : 0.0;

  // ── Heads: aim at each other while breathing, face each other in the kiss.
  vec3 r0 = bp(-1.0, 0.0), r1 = bp(-1.0, 0.035), b0 = bp(1.0, 0.0), b1 = bp(1.0, 0.035);
  vec2 tR = normalize(r0.xy - r1.xy + 1e-5), tB = normalize(b0.xy - b1.xy + 1e-5);
  vec2 dR = turn(tR, normalize(b0.xy - r0.xy + 1e-5), min(eR * 2.0, 1.0));
  vec2 dB2 = turn(tB, normalize(r0.xy - b0.xy + 1e-5), min(eB * 2.0, 1.0));
  dR = turn(dR, vec2(1.0, 0.0), kz);
  dB2 = turn(dB2, vec2(-1.0, 0.0), kz);
  // Heads stay upright: the top is the side facing up the screen, foreshortened as a head
  // turns through vertical (hy is +-1/thinness).
  float hR = (dR.x >= 0.0 ? 1.0 : -1.0) / clamp(abs(dR.x) * 2.5, 0.45, 1.0);
  float hB = (dB2.x >= 0.0 ? 1.0 : -1.0) / clamp(abs(dB2.x) * 2.5, 0.45, 1.0);
  vec2 mR = r0.xy + dR * L * 0.9 - vec2(-dR.y, dR.x) * sign(hR) * 0.08 * L;
  vec2 mB = b0.xy + dB2 * L * 0.9 - vec2(-dB2.y, dB2.x) * sign(hB) * 0.08 * L;
  float gap = length(mB - mR);
  float lR = clash ? gap * 0.5 + 0.03 : gap * p_reach;
  float lB = lR;
  lR *= min(eR * 1.5, 1.0) * (0.85 + 0.15 * k);
  lB *= min(eB * 1.5, 1.0) * (0.85 + 0.15 * k);
  vec2 aR = normalize(mB - mR + 1e-5), aB = -aR;

  // ── Night.
  vec3 col = vec3(0.0);
  float stars = p_stars * (brk ? 2.0 : 1.0);
  vec2 sg = floor(uv * vec2(u_aspect, 1.0) / u_px / 3.0);
  float sh = hash(sg);
  col += vec3(0.8, 0.85, 1.0) * step(0.996, sh) * (0.5 + 0.5 * sin(u_beat * 1.5 + hash(sg + 3.0) * 30.0)) * stars;

  // ── Kiss heart glowing behind them.
  vec3 purple = hsv(0.83, 0.65, 1.0);
  float hk = kz * p_hearts;
  if (hk > 0.01) {
    float hd = sdHeart((p - vec2(0.0, -0.37)) / 0.72) * 0.72;
    col += purple * hk * (0.1 * step(hd, 0.0) * (0.7 + 0.3 * k) + 0.5 * exp(-abs(hd) * 30.0)) ;
  }

  // ── Bodies, far one first, each with its glow.
  vec4 qR = bodyQ(p, -1.0), qB = bodyQ(p, 1.0);
  float gl = p_glow * (brk ? 1.5 : 1.0) * (1.0 + p_punch * k);
  col += redC * 0.35 * gl * exp(-max(qR.x, 0.0) / 0.035);
  col += bluC * 0.35 * gl * exp(-max(qB.x, 0.0) / 0.035);
  col += redC * 0.25 * gl * exp(-length(p - r0.xy) / 0.06);
  col += bluC * 0.25 * gl * exp(-length(p - b0.xy) / 0.06);
  bool redFar = qR.w > qB.w;
  for (int i = 0; i < 2; i++) {
    bool isRed = (i == 0) == redFar;
    if (isRed) {
      drawLimbs(col, p, -1.0, redC, redH, redHorn);
      drawBody(col, qR, redC, redB, redH, 1.0);
      drawHead(col, p, r0.xy, dR, hR, redC, redB, redH, redHorn, redEye, eR);
    } else {
      drawLimbs(col, p, 1.0, bluC, bluH, bluHorn);
      drawBody(col, qB, bluC, bluB, bluH, 1.0);
      drawHead(col, p, b0.xy, dB2, hB, bluC, bluB, bluH, bluHorn, bluEye, eB);
    }
  }

  // ── Fire and ice.
  float pk = 0.8 + 0.4 * k * p_punch;
  col += blast(p, mR, aR, lR, 0.0, p_rhue, pk);
  col += blast(p, mB, aB, lB, 1.0, p_bhue, pk);
  float ce = clash ? env * bamt * p_clash : 0.0;
  if (ce > 0.01) {
    vec2 X = (mR + mB) * 0.5;
    vec2 rp = p - X;
    vec2 ax = aR, pr = vec2(-ax.y, ax.x);
    float wy = dot(rp, pr) / (0.07 + 0.1 * k);
    float wall = exp(-abs(dot(rp, ax)) / 0.02 - wy * wy);
    col += vec3(0.95, 0.8, 1.0) * ce * (1.4 * exp(-length(rp) / 0.04) + 0.9 * wall) * (0.7 + 0.6 * k);
    for (int j = 0; j < 16; j++) {
      float fj = float(j);
      float ph = fract(u_beat * 1.3 + hash(vec2(fj, 2.0)));
      float an = hash(vec2(fj, 1.0)) * TAU;
      vec2 sp = X + vec2(cos(an), sin(an)) * ph * (0.12 + 0.18 * hash(vec2(fj, 3.0))) - vec2(0.0, 0.05 * ph * ph);
      vec3 spc = mod(fj, 2.0) < 0.5 ? vec3(1.0, 0.6, 0.15) : vec3(0.5, 0.9, 1.0);
      float sd = length(p - sp);
      col += spc * ce * (1.0 - ph) * (exp(-sd / 0.004) * 1.5 + exp(-sd / 0.02) * 0.3);
    }
  }

  // ── The kiss: a flash, a ring, little hearts.
  if (kz > 0.01 && p_hearts > 0.0) {
    vec2 K = (mR + mB) * 0.5;
    float r = length(p - K);
    float t = max(tk, 0.0);
    float burst = tk >= -0.5 ? exp(-t * 0.7) : 0.0;
    col += purple * p_hearts * (kz * 0.5 * exp(-r / 0.05) * (0.6 + 0.4 * k) + burst * 1.5 * exp(-r / (0.06 + 0.05 * t)));
    col += mix(redH, bluH, 0.5 + 0.5 * sin(atan(p.y - K.y, p.x - K.x) * 3.0)) * burst * p_hearts * exp(-abs(r - t * 0.16) / 0.012);
    for (int j = 0; j < 6; j++) {
      float fj = float(j);
      float ph = fract(u_beat / 4.0 + fj / 6.0);
      vec2 hp = K + vec2(0.35 * (hash(vec2(fj, 9.0)) - 0.5) + 0.03 * sin(ph * 9.0 + fj), 0.04 + ph * 0.42);
      float s = 0.045 * (0.6 + 0.4 * hash(vec2(fj, 4.0)));
      float hd = sdHeart((p - hp) / s + vec2(0.0, 0.5)) * s;
      float a = kz * p_hearts * sin(PI * ph);
      vec3 hc = mod(fj, 2.0) < 0.5 ? hsv(0.92, 0.55, 1.0) : purple;
      paint(col, hd, mix(col, hc, a), g_px);
      col += hc * a * 0.25 * exp(-max(hd, 0.0) / 0.01);
    }
  }

  col = max(col, 0.0) * p_bright;
  return clamp(col, 0.0, 1.0);
}
