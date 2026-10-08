// Flow: particles streaming through a noise flow field, leaving fading trails (after
// "Flow Field with Particle Trails" in Paul Bakaus's Radiant collection, MIT). The original
// keeps its trails by never clearing a Canvas 2D frame; sketches have no frame memory, so
// each pixel traces its streamline backwards instead. Every grid cell releases a particle
// from a seed point once per lifetime; a pixel is lit when its streamline passes a seed and
// that particle's head went past the pixel less than a trail length ago. Seeds move each
// lifetime, so there are no fixed sources. Beat-locked: speed is in surface heights per beat.
// Cost: half-cell steps (each checking the two cells it crosses) and one noise with its gradient a
// step, about a third of the first version's work for the same trails.
// Params are p_* uniforms; ranges and defaults are in flow.json.
uniform float p_scale, p_curl, p_evolve, p_density, p_speed, p_trail, p_width, p_vary, p_steps,
              p_punch, p_push, p_hue, p_spread, p_sat, p_bright, p_bg, p_follow;

#define TAU 6.2831853
#define MAXSTEPS 16

// 3D simplex noise (Ian McEwan, Ashima Arts; MIT).
vec4 permute(vec4 x) { return mod(((x * 34.0) + 1.0) * x, 289.0); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
float snoise(vec3 v) {
  const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
  const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
  vec3 i = floor(v + dot(v, C.yyy));
  vec3 x0 = v - i + dot(i, C.xxx);
  vec3 g = step(x0.yzx, x0.xyz);
  vec3 l = 1.0 - g;
  vec3 i1 = min(g.xyz, l.zxy);
  vec3 i2 = max(g.xyz, l.zxy);
  vec3 x1 = x0 - i1 + C.xxx;
  vec3 x2 = x0 - i2 + C.yyy;
  vec3 x3 = x0 - D.yyy;
  i = mod(i, 289.0);
  vec4 p = permute(permute(permute(i.z + vec4(0.0, i1.z, i2.z, 1.0))
                                 + i.y + vec4(0.0, i1.y, i2.y, 1.0))
                                 + i.x + vec4(0.0, i1.x, i2.x, 1.0));
  vec3 ns = (1.0 / 7.0) * D.wyz - D.xzx;
  vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
  vec4 x_ = floor(j * ns.z);
  vec4 y_ = floor(j - 7.0 * x_);
  vec4 x = x_ * ns.x + ns.yyyy;
  vec4 y = y_ * ns.x + ns.yyyy;
  vec4 h = 1.0 - abs(x) - abs(y);
  vec4 b0 = vec4(x.xy, y.xy);
  vec4 b1 = vec4(x.zw, y.zw);
  vec4 s0 = floor(b0) * 2.0 + 1.0;
  vec4 s1 = floor(b1) * 2.0 + 1.0;
  vec4 sh = -step(h, vec4(0.0));
  vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
  vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
  vec3 p0 = vec3(a0.xy, h.x);
  vec3 p1 = vec3(a0.zw, h.y);
  vec3 p2 = vec3(a1.xy, h.z);
  vec3 p3 = vec3(a1.zw, h.w);
  vec4 nrm = taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
  p0 *= nrm.x; p1 *= nrm.y; p2 *= nrm.z; p3 *= nrm.w;
  vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
  m = m * m;
  return 42.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

// The same noise with its gradient (Stefan Gustavson's noise3Dgrad, MIT): one call gives the flow
// direction here and how it turns nearby, so the side trace needs no second noise.
float snoiseG(vec3 v, out vec3 grad) {
  const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
  const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
  vec3 i = floor(v + dot(v, C.yyy));
  vec3 x0 = v - i + dot(i, C.xxx);
  vec3 g = step(x0.yzx, x0.xyz);
  vec3 l = 1.0 - g;
  vec3 i1 = min(g.xyz, l.zxy);
  vec3 i2 = max(g.xyz, l.zxy);
  vec3 x1 = x0 - i1 + C.xxx;
  vec3 x2 = x0 - i2 + C.yyy;
  vec3 x3 = x0 - D.yyy;
  i = mod(i, 289.0);
  vec4 p = permute(permute(permute(i.z + vec4(0.0, i1.z, i2.z, 1.0))
                                 + i.y + vec4(0.0, i1.y, i2.y, 1.0))
                                 + i.x + vec4(0.0, i1.x, i2.x, 1.0));
  vec3 ns = (1.0 / 7.0) * D.wyz - D.xzx;
  vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
  vec4 x_ = floor(j * ns.z);
  vec4 y_ = floor(j - 7.0 * x_);
  vec4 x = x_ * ns.x + ns.yyyy;
  vec4 y = y_ * ns.x + ns.yyyy;
  vec4 h = 1.0 - abs(x) - abs(y);
  vec4 b0 = vec4(x.xy, y.xy);
  vec4 b1 = vec4(x.zw, y.zw);
  vec4 s0 = floor(b0) * 2.0 + 1.0;
  vec4 s1 = floor(b1) * 2.0 + 1.0;
  vec4 sh = -step(h, vec4(0.0));
  vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
  vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
  vec3 p0 = vec3(a0.xy, h.x);
  vec3 p1 = vec3(a0.zw, h.y);
  vec3 p2 = vec3(a1.xy, h.z);
  vec3 p3 = vec3(a1.zw, h.w);
  vec4 nrm = taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
  p0 *= nrm.x; p1 *= nrm.y; p2 *= nrm.z; p3 *= nrm.w;
  vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
  vec4 m2 = m * m, m4 = m2 * m2;
  vec4 pdotx = vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3));
  vec4 t = m2 * m * pdotx;
  grad = 42.0 * (-8.0 * (t.x * x0 + t.y * x1 + t.z * x2 + t.w * x3) + m4.x * p0 + m4.y * p1 + m4.z * p2 + m4.w * p3);
  return 42.0 * dot(m4, pdotx);
}

// Flow direction at q (surface heights from the centre). The original steers by noise * 2π;
// Push bends the streams away from the centre on the kick. turn: how fast the direction's angle
// changes across the field here (radians per surface height), for the side trace.
vec2 flowDir(vec2 q, float z, float push, out vec2 turn) {
  vec3 g;
  float a = snoiseG(vec3(q * p_scale, z), g) * TAU * p_curl;
  turn = g.xy * p_scale * TAU * p_curl;
  vec2 d = vec2(cos(a), sin(a));
  float r = length(q);
  d += push * q / max(r, 1e-3) * exp(-2.0 * r * r);
  return d / max(length(d), 1e-3);
}

// One particle's mark on this pixel: the particle of cell c, against the trace segment q -> q1,
// i steps (of h) downstream of it. J is the stream spreading, 0..1.
float particle(vec2 c, vec2 q, vec2 q1, float i, float h, float J, float t, float life, float reach, float r, float k) {
  float age = t / life + hash(c + 0.37);        // in lifetimes, staggered per cell
  float gen = floor(age);
  float A = age - gen;                           // 0..1 through this particle's life
  vec2 seed = (c + 0.25 + 0.5 * vec2(hash(c + gen * 1.31 + 5.1), hash(c + gen * 2.17 + 9.7))) / p_density;
  vec2 ba = q1 - q, pa = seed - q;
  float f = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  float d = length(pa - ba * f) / J;             // distance from the particle's path, in this pixel's units
  float s = (i + f) * h;                         // seed to this pixel, downstream
  float behind = A * reach - s;                  // how far the head is past this pixel
  float v = hash(c + gen * 0.73 + 3.3);          // per-particle width and alpha, like the original
  float rw = r * mix(1.0, 0.35 + 1.3 * v, p_vary) * (1.0 + 0.5 * p_punch * k);
  float line = 1.0 - smoothstep(rw - 0.75 * u_px, rw + 0.75 * u_px, d);
  float trail = step(0.0, behind) * exp(-2.0 * behind / max(p_trail, 1e-3));
  float alpha = mix(1.0, 0.35 + 0.65 * hash(c + gen * 0.51 + 7.7), p_vary);
  float fade = smoothstep(0.0, 0.08, A) * (1.0 - smoothstep(0.85, 1.0, A));
  return line * trail * alpha * fade;
}

vec3 content(vec2 uv) {
  float t = u_beat;
  float k = kick();
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
  float z = t * p_evolve;

  float cell = 1.0 / p_density;                 // one particle per cell
  float h = 0.5 * cell;                          // trace step: half a cell, so a segment touches at most two cells
  float reach = p_steps * h;                     // how far a particle travels in its life
  float life = reach / max(p_speed, 1e-3);       // in beats
  float r = 0.5 * p_width * u_px;                // line half-width

  // A side trace one pixel over measures how much the stream spreads between the seed and here.
  // Without it, where the flow diverges, every pixel whose stream squeezes past a seed lights up and
  // the thin trail becomes a fan. Its direction comes from the main trace's (turned by the field's
  // gradient across the gap), so it costs no noise of its own.
  vec2 tn;
  vec2 d0 = flowDir(p, z, p_push * k, tn);
  vec2 q = p, qs = p + vec2(-d0.y, d0.x) * u_px;

  float lit = 0.0;
  vec2 dprev = d0;
  for (int i = 0; i < MAXSTEPS; i++) {
    if (float(i) >= p_steps) break;
    vec2 dq = flowDir(q, z, p_push * k, tn);
    // A trace that doubles back has reached a point the streams fan out from and
    // would bounce there, lighting the whole fan. No particle comes from there: stop.
    if (dot(dq, dprev) < -0.2) break;
    dprev = dq;
    vec2 q1 = q - dq * h;                          // one step upstream
    float da = dot(tn, qs - q);                    // the side trace's direction: this one, turned by the gap
    vec2 ds = vec2(dq.x * cos(da) - dq.y * sin(da), dq.x * sin(da) + dq.y * cos(da));
    vec2 qs1 = qs - ds * h;
    // Seed-side spacing per pixel here, capped: where streams merge the side trace can jump to
    // another stream. Only the sideways part counts (shear turns spacing along the stream).
    vec2 sep = ((qs + qs1) - (q + q1)) * 0.5;
    float J = clamp(abs(sep.x * dq.y - sep.y * dq.x) / u_px, 1e-3, 1.0);
    // The particles of the one or two cells this step crosses.
    vec2 c0 = floor(q * p_density), c1 = floor(q1 * p_density);
    lit = max(lit, particle(c0, q, q1, float(i), h, J, t, life, reach, r, k));
    if (c1 != c0) lit = max(lit, particle(c1, q, q1, float(i), h, J, t, life, reach, r, k));
    q = q1; qs = qs1;
  }

  // Colour by a second, slower noise, as in the original's palette lookup.
  float cn = snoise(vec3(p * p_scale * 1.5 + 100.0, z * 0.5));
  float hue = mix(p_hue, u_hue, p_follow) + cn * p_spread;
  vec3 col = hsv(hue, p_sat, 1.0) * p_bright * (1.0 + p_punch * k);
  return mix(vec3(p_bg), col, lit);
}
