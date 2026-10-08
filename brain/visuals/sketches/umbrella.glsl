// Umbrella: looking up through a rain-soaked umbrella at a blurred night city (after
// "Rain on Umbrella" in Paul Bakaus's Radiant collection, MIT). The original simulates
// drops on a 2D canvas every frame (landing, merging, sliding, trails) and hands that to
// a refraction shader as a texture; sketches have no frame memory or canvas, so this is a
// stateless rebuild of the look: every cell of two grids has a drop that lands, sits,
// then slides outward down the dome leaving a trail of droplets, and comes back
// somewhere new each life (impacts can land on the beat). Each drop is a lens onto a
// sharper, displaced view of the city bokeh behind it. The umbrella ribs, panels and hub
// are the original's shader code (applyUmbrellaRibs), nearly line for line.
// Params are p_* uniforms; ranges and defaults are in umbrella.json.
uniform float p_rain, p_size, p_life, p_slide, p_onbeat, p_refr, p_trail, p_micro, p_walk,
              p_ribs, p_blur, p_lights, p_punch, p_hue, p_follow, p_bright;

#define PI 3.14159265
#define TAU 6.2831853

vec2 hash2(vec2 p) { return vec2(hash(p), hash(p + 17.31)); }

// ── The city through the fabric: bokeh lights, tiled sideways so the walk can go on.
// sharp 0 = the blurred view between drops, 1 = the crisper view through a drop. ──
vec3 city(vec2 p, float sharp) {
  vec3 c = vec3(0.04, 0.031, 0.071);                 // the original's #0a0812
  float W = 2.2 * max(u_aspect, 1.0);
  p.x += u_beat * p_walk * 0.02;
  for (int i = 0; i < 28; i++) {
    float fi = float(i);
    vec2 hh = hash2(vec2(fi, 3.1));
    float sz = hash(vec2(fi, 7.7)), hr = hash(vec2(fi, 9.1));
    float R = sz < 0.35 ? 0.12 + 0.22 * hr : (sz < 0.7 ? 0.06 + 0.09 * hr : 0.025 + 0.035 * hr);
    vec2 lp = vec2((hh.x - 0.5) * W, (hh.y - 0.5) * 1.1 - (R > 0.12 ? 0.18 : 0.0));   // big ones overhead
    float dx = mod(p.x - lp.x + 0.5 * W, W) - 0.5 * W;
    float d = length(vec2(dx, p.y - lp.y));
    float edge = R * mix(0.9 * p_blur, 0.1, sharp);
    if (d >= R + 0.25 * edge) continue;                  // outside this light: skip its colour (most pixels, most lights)
    float disk = 1.0 - smoothstep(R - edge, R + 0.25 * edge, d);
    float core = 1.0 - 0.5 * clamp(d / R, 0.0, 1.0);             // solid centre, not a ring
    float sel = hash(vec2(fi, 5.3)), hv = hash(vec2(fi, 6.1));
    float hue = sel < 0.35 ? 0.06 + 0.06 * hv : (sel < 0.55 ? 0.02 + 0.04 * hv : (sel < 0.7 ? 0.1 + 0.06 * hv : (sel < 0.85 ? 0.55 + 0.11 * hv : 0.86 + 0.11 * hv)));
    float sat = sel < 0.7 ? 0.85 : 0.6;
    float a = (0.2 + 0.35 * hash(vec2(fi, 8.3))) * (1.0 - 0.3 * step(0.7, sel));
    c += hsv(hue, sat, 0.9) * disk * core * a * p_lights;
  }
  // Ambient washes: the whole city's glow through the fabric, as in the original.
  for (int i = 0; i < 8; i++) {
    float fi = float(i);
    vec2 hh = hash2(vec2(fi, 31.3));
    vec2 lp = vec2((hh.x - 0.5) * W, -0.4 + 0.8 * hh.y);
    float dx = mod(p.x - lp.x + 0.5 * W, W) - 0.5 * W;
    float d = length(vec2(dx, p.y - lp.y));
    float R = 0.3 + 0.45 * hash(vec2(fi, 32.1));
    if (d > 2.6 * R) continue;                            // its glow is under 1/1000 out here
    float sel = hash(vec2(fi, 33.7));
    float hue = sel > 0.45 ? 0.055 + 0.07 * hash(vec2(fi, 34.9)) : (sel > 0.2 ? 0.72 + 0.14 * hash(vec2(fi, 34.9)) : 0.86 + 0.08 * hash(vec2(fi, 34.9)));
    c += hsv(hue, 0.5, 0.28) * exp(-d * d / (R * R * 0.5)) * 0.35 * p_lights;
  }
  // Streetlight cores with warm halos.
  for (int i = 0; i < 6; i++) {
    float fi = float(i);
    vec2 hh = hash2(vec2(fi, 21.7));
    vec2 lp = vec2((hh.x - 0.5) * W, -0.45 + 0.5 * hh.y);
    float dx = mod(p.x - lp.x + 0.5 * W, W) - 0.5 * W;
    float d = length(vec2(dx, p.y - lp.y));
    float R = 0.012 + 0.03 * hash(vec2(fi, 22.9));
    if (d > 35.0 * R) continue;                           // past its halo (under 1/1000)
    float hue = hash(vec2(fi, 23.3)) > 0.25 ? 0.06 + 0.07 * hash(vec2(fi, 24.1)) : 0.53 + 0.08 * hash(vec2(fi, 24.1));
    float coreR = R * mix(2.2 * p_blur, 1.0, sharp);
    c += hsv(hue, 0.5, 1.0) * exp(-d * d / (coreR * coreR * 0.15)) * 0.8 * p_lights;
    c += hsv(hue, 0.7, 0.6) * exp(-d / (R * 5.0)) * 0.12 * p_lights;
  }
  return c;
}

// ── One grid of drops. Returns (lens normal xy, coverage, thickness). ──
vec4 dropLayer(vec2 p, float cs, float seed, float t) {
  vec2 id0 = floor(p / cs);
  vec4 best = vec4(0.0);
  for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
    vec2 c = id0 + vec2(float(i), float(j));
    if (hash(c + seed + 5.3) > p_rain) continue;
    float T = p_life * (0.6 + 0.8 * hash(c + seed + 2.2));
    float off = hash(c + seed + 8.8) * T;
    if (p_onbeat > 0.5) { T = floor(T + 0.5); off = floor(off); }   // impacts on the beat
    T = max(T, 1.0);
    float age = (t + off) / T;
    float gen = floor(age), ph = age - gen;
    vec2 p0 = (c + 0.2 + 0.6 * hash2(c + seed + gen * 1.37)) * cs;   // a new spot each life
    vec2 dir = length(p0) > 1e-3 ? normalize(p0) : vec2(0.0, 1.0);  // down the dome
    vec2 prp = vec2(-dir.y, dir.x);
    float r = cs * (0.14 + 0.2 * hash(c + seed + gen * 2.1));
    float slide = smoothstep(0.35, 1.0, ph); slide *= slide;         // sits, then accelerates
    float travel = slide * cs * p_slide * (0.6 + 1.5 * length(p0));  // steeper toward the rim
    vec2 pos = p0 + dir * travel;
    float spread = 1.0 + 0.9 * (1.0 - smoothstep(0.0, 0.06, ph));    // flattens on impact
    float life = smoothstep(0.0, 0.02, ph) * (1.0 - smoothstep(0.88, 1.0, ph));

    vec2 q = p - pos;
    vec2 lq = vec2(dot(q, prp), dot(q, dir) / (1.0 + 0.7 * slide)) / (r * spread);
    float d = length(lq);
    float m = (1.0 - smoothstep(0.8, 1.0, d)) * life;
    if (m > best.z) best = vec4(lq, m, sqrt(max(1.0 - d * d, 0.0)));

    // The trail it leaves: small droplets strung along its path, drying as it goes.
    if (p_trail > 0.0 && travel > r) {
      vec2 w = p - p0;
      float s = dot(w, dir);
      if (s > 0.0 && s < travel - 0.8 * r) {
        float spc = r * 0.9;
        float k = floor(s / spc);
        float tr = r * 0.3 * (0.6 + 0.8 * hash(c + seed + k * 3.1 + gen)) * p_trail;
        vec2 tq = vec2(dot(w, prp) - (hash(c + seed + k * 1.7 + gen) - 0.5) * r * 0.4, s - (k + 0.5) * spc) / max(tr, 1e-4);
        float td = length(tq);
        float tm = (1.0 - smoothstep(0.75, 1.0, td)) * life * (1.0 - 0.6 * (travel - s) / max(travel, 1e-3));
        if (tm > best.z) best = vec4(tq, tm, sqrt(max(1.0 - td * td, 0.0)) * 0.5);
      }
    }
  }
  return best;
}

// ── Micro-droplets: specks that bead up and dry. ──
vec4 micro(vec2 p, float cs, float t) {
  vec2 c = floor(p / cs);
  if (hash(c + 41.0) > p_micro) return vec4(0.0);
  float ph = fract(t / (6.0 + 10.0 * hash(c + 42.0)) + hash(c + 43.0));
  vec2 ctr = (c + 0.3 + 0.4 * hash2(c + 44.0)) * cs;
  float r = cs * (0.08 + 0.12 * hash(c + 45.0));
  vec2 q = (p - ctr) / r;
  float d = length(q);
  float m = (1.0 - smoothstep(0.7, 1.0, d)) * smoothstep(0.0, 0.15, ph) * (1.0 - smoothstep(0.6, 1.0, ph));
  return vec4(q, m, sqrt(max(1.0 - d * d, 0.0)) * 0.4);
}

// ── The umbrella: ribs, billowing panels, the hub (the original's code). ──
vec3 applyUmbrellaRibs(vec3 color, vec2 pos) {
  vec2 dir = pos - vec2(0.5);
  dir.x *= u_aspect;
  float dist = length(dir);
  float ang = atan(dir.y, dir.x);
  float SECTOR = PI * 2.0 / 8.0;
  float secAng = mod(ang + SECTOR * 0.5, SECTOR) - SECTOR * 0.5;
  float ribIdx = floor((ang + PI) / SECTOR);
  float wobble = sin(dist * 16.0 + ribIdx * 4.7) * 0.018 * dist + sin(dist * 37.0 - ribIdx * 2.3) * 0.008 * dist;
  secAng += wobble * smoothstep(0.0, 0.1, dist);
  float screenDist = abs(secAng) * dist;
  float ribW = mix(0.006, 0.0008, smoothstep(0.0, 0.55, dist));
  ribW = max(ribW, 0.7 * u_px);                     // keep the rib a pixel wide on the projector
  float rib = (1.0 - smoothstep(ribW * 0.15, ribW, screenDist)) * (1.0 - smoothstep(0.55, 0.75, dist));
  float side = step(0.0, secAng) * 2.0 - 1.0;
  float highlight = rib * 0.06 * max(0.0, side);
  float shadow = rib * 0.14;
  float panelEdge = smoothstep(0.0, SECTOR * 0.35 * max(0.01, dist), screenDist);
  float panelShade = (1.0 - panelEdge * panelEdge) * 0.025 * smoothstep(0.03, 0.25, dist);
  float panelTint = mod(ribIdx, 2.0) * 0.012 - 0.006;
  float cap = (1.0 - smoothstep(0.008, 0.016, dist)) * 0.18;
  float ring = max(0.0, 1.0 - abs(dist - 0.02) / 0.004) * 0.06;
  float vig = smoothstep(0.05, 0.7, dist);
  float darken = (shadow + panelShade + cap + ring) * p_ribs + vig * vig * 0.14;
  return color * (1.0 - darken) + vec3(highlight + panelTint) * p_ribs;
}

vec3 hueShift(vec3 c, float turns) {
  float a = turns * TAU;
  vec3 k = vec3(0.57735);
  float ca = cos(a);
  return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
  float t = u_beat;
  float k = kick();

  vec4 dr = dropLayer(p, 0.17 * p_size, 0.0, t);
  vec4 d2 = dropLayer(p, 0.1 * p_size, 11.0, t * 1.13 + 3.0);
  if (d2.z > dr.z) dr = d2;
  vec4 d3 = micro(p, 0.03 * p_size, t);
  if (d3.z > dr.z) dr = d3;
  vec2 n = dr.xy;
  float m = clamp(dr.z, 0.0, 1.0);

  // Between drops: the soft, blurred city. Through a drop: a sharper piece of it,
  // displaced by the lens (the original shifted by up to 512 px).
  float lit = 1.0 + p_punch * k * 0.35;
  vec3 col = city(p, 0.0) * lit;
  if (m > 0.001) {
    vec3 through = city(p - n * p_refr * (0.1 + 0.18 * dr.w), 1.0) * lit * 1.04;
    float rim = smoothstep(0.55, 1.0, length(n));
    through *= 1.0 - 0.45 * rim;                                          // dark lens edge
    through += vec3(1.0, 0.95, 0.9) * pow(max(dot(n, normalize(vec2(-0.45, -0.6))), 0.0), 8.0) * 0.35 * dr.w;
    col = mix(col, through, m);
  }

  col = applyUmbrellaRibs(col, uv);
  col = hueShift(max(col, 0.0), p_hue + p_follow * u_hue);
  // A soft lift for the projector, which crushes dark mids: darks and mids up about 1.8x, highlights eased, black stays black.
  return clamp((1.0 - exp(-col * p_bright * 2.2)) / (1.0 - exp(-2.2)), 0.0, 1.0);
}
