// Elevated: a flight low over eroded mountains at dusk, in the spirit of RGBA's 2009 4k demo
// "Elevated" (the technique only: fbm terrain with derivative erosion, raymarched; none of its code).
// The land is shaped by the song: the ground at each point along the flight is as tall as the
// track's waveform (wave()) is loud at the beat you'll fly over it, so a loud section is a range
// of peaks you fly into exactly as it plays, and a breakdown is a valley floor. It never moves
// under you: distance along the flight is beats x Speed. The camera skims low through the quiet
// parts and climbs as a drop builds (dropArc), banking with the synths; the sun flares on the kick.
// Dusk colours: mauve rock, lavender snow, a pink sun in a blue haze. Nothing goes yellow.
// The heavy one: Steps trades detail for frame rate. Params are p_* uniforms; see elevated.json.
uniform float p_speed, p_height, p_shape, p_alt, p_climb, p_bank, p_steps, p_far, p_snow,
              p_fog, p_sun, p_punch, p_hue, p_follow, p_bright;

float el_h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float el_hue(float h) {
  h = fract(h);
  if (h > 0.03 && h < 0.36) { float o = 0.03 + (h - 0.03) / 0.33 * 0.175; return o >= 0.095 ? o + 0.155 : o; }
  return h;
}
vec3 el_col(float h, float s, float v) { return hsv(el_hue(h), s, v); }
// Value noise and its derivatives (the derivatives are what make the erosion).
vec3 el_noised(vec2 x) {
  vec2 p = floor(x), f = fract(x);
  vec2 u = f * f * (3.0 - 2.0 * f), du = 6.0 * f * (1.0 - f);
  float a = el_h(p), b = el_h(p + vec2(1.0, 0.0)), c = el_h(p + vec2(0.0, 1.0)), d = el_h(p + vec2(1.0, 1.0));
  return vec3(a + (b - a) * u.x + (c - a) * u.y + (a - b - c + d) * u.x * u.y,
              du * (vec2(b - a, c - a) + (a - b - c + d) * u.yx));
}
const mat2 EL_M = mat2(0.8, -0.6, 0.6, 0.8);
// The land's shape (0..~1): fbm where steep places get less detail, like eroded rock.
float el_fbm(vec2 x, float oct) {
  float a = 0.0, b = 1.0;
  vec2 d = vec2(0.0);
  for (int i = 0; i < 9; i++) {
    if (float(i) >= oct) break;
    vec3 n = el_noised(x);
    d += n.yz;
    a += b * n.x / (1.0 + dot(d, d));
    b *= 0.5;
    x = EL_M * x * 2.0;
  }
  return a;
}
// How tall the land is along the flight: the waveform's loudness at the beat you'll fly over it.
float el_amp(float z) {
  if (u_wv.w < 0.5) return 0.9;
  float b = z / max(p_speed, 0.05);
  float w = (wave(b - 1.0).x + wave(b).x * 2.0 + wave(b + 1.0).x) * 0.25;
  return mix(0.35, 1.35, pow(clamp(w, 0.0, 1.0), max(p_shape, 0.2)));
}
float el_land(vec2 xz, float oct) { return 7.0 * p_height * el_amp(xz.y) * el_fbm(xz * 0.06, oct); }

vec3 content(vec2 uv) {
  vec2 p = (uv - 0.5) * vec2(u_aspect, 1.0);
  p.y = -p.y;
  float k = kick(), arc = dropArc();
  float M = u_wv.w > 0.0 ? wave(u_beat).z : 0.5;
  float H = p_hue + (p_follow > 0.5 ? u_hue - 0.62 : 0.0);

  // The camera: flying along +z, a little above the land, higher as a drop builds.
  float cz = u_beat * p_speed;
  vec2 cxz = vec2(6.0 * sin(u_beat * 0.019), cz);
  float ground = max(max(el_land(cxz, 5.0), el_land(cxz + vec2(0.0, 3.0), 5.0)), el_land(cxz + vec2(0.0, 6.0), 5.0));
  float alt = p_alt * (1.0 + p_climb * 1.5 * arc);
  vec3 ro = vec3(cxz.x, ground + alt, cxz.y);
  vec3 ta = vec3(6.0 * sin(u_beat * 0.019 + 0.3), ground + alt * 0.7 - 0.5, cz + 14.0);
  vec3 fw = normalize(ta - ro);
  float roll = p_bank * 0.1 * (sin(u_beat * 0.07) + (M - 0.5));
  vec3 rt = normalize(cross(vec3(sin(roll), cos(roll), 0.0), fw)), up = cross(fw, rt);
  vec3 rd = normalize(p.x * rt + p.y * up + 1.6 * fw);

  // Sky: blue haze above, pink towards the low sun, which flares on the kick.
  vec3 sunDir = normalize(vec3(-0.55, 0.12, 1.0));
  float sd = max(dot(rd, sunDir), 0.0);
  vec3 sky = mix(el_col(0.93 + H, 0.45, 0.85), el_col(0.62 + H, 0.55, 0.45), smoothstep(-0.05, 0.45, rd.y));
  sky += el_col(0.95 + H, 0.35, 1.0) * (pow(sd, 16.0) * 0.25 + pow(sd, 900.0) * 2.0) * p_sun * (1.0 + 0.6 * p_punch * k);

  // March the ray over the land.
  float t = 0.1, far = p_far, hit = -1.0;
  float steps = floor(p_steps);
  for (int i = 0; i < 160; i++) {
    if (float(i) >= steps) break;
    vec3 q = ro + rd * t;
    float d = q.y - el_land(q.xz, 5.0);
    if (d < 0.002 * t) { hit = t; break; }
    if (t > far) break;
    t += max(0.5 * d, 0.01 + 0.003 * t);
  }
  // A ray that ran out of steps short of the view distance is skimming a ridge: count it as land,
  // or ridgelines sparkle with sky.
  if (hit < 0.0 && t < far) hit = t;

  vec3 col = sky;
  if (hit > 0.0) {
    vec3 q = ro + rd * hit;
    // Shade with a little more detail than the march found, fading with distance, and a normal
    // taken over a footprint that grows with distance: more would sparkle.
    vec2 e = vec2(0.03 + 0.004 * hit, 0.0);
    float oct = 6.0 - clamp(hit * 0.06, 0.0, 2.0);
    float h0 = el_land(q.xz, oct);
    vec3 n = normalize(vec3(h0 - el_land(q.xz + e.xy, oct), e.x, h0 - el_land(q.xz + e.yx, oct)));
    // Rock, with lavender snow on high, flatter places.
    vec3 rock = mix(el_col(0.02 + H, 0.3, 0.2), el_col(0.8 + H, 0.25, 0.28), el_fbm(q.xz * 0.3, 3.0));
    float snow = smoothstep(0.6, 0.85, n.y) * smoothstep(2.5, 4.5, q.y / max(p_height, 0.2)) * p_snow;
    vec3 alb = mix(rock, vec3(0.86, 0.84, 0.98), clamp(snow, 0.0, 1.0));
    float dif = clamp(dot(n, sunDir), 0.0, 1.0);
    // A soft shadow: is there land between here and the sun?
    float sh = 1.0;
    float st = 0.1;
    for (int j = 0; j < 16; j++) {
      vec3 sp = q + sunDir * st;
      float dd = sp.y - el_land(sp.xz, 4.0);
      sh = min(sh, 8.0 * dd / st);
      st += clamp(dd, 0.1, 1.0);
      if (sh < 0.0 || st > 12.0) break;
    }
    sh = clamp(sh, 0.0, 1.0);
    vec3 lin = el_col(0.96 + H, 0.3, 1.0) * 1.6 * dif * sh * (1.0 + 0.3 * p_punch * k)
             + el_col(0.62 + H, 0.4, 0.5) * (0.5 + 0.5 * n.y)
             + el_col(0.9 + H, 0.3, 0.25) * clamp(-dot(n, sunDir), 0.0, 1.0);
    col = alb * lin;
    // Haze: blue with distance, pinker towards the sun.
    vec3 fogc = mix(el_col(0.62 + H, 0.45, 0.6), el_col(0.93 + H, 0.4, 0.85), pow(sd, 4.0));
    col = mix(col, fogc, 1.0 - exp(-hit * 0.022 * p_fog));
  }
  col = pow(col, vec3(0.85));                                        // a touch brighter in the shadows
  return col * p_bright * (1.0 + 0.15 * arc);
}
