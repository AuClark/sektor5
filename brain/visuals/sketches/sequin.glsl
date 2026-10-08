// Sequin: thousands of tiny mirror discs on a hex grid, tilted by interfering waves and
// flashing as they catch the light (after "Sequin Wave" in Paul Bakaus's Radiant
// collection, MIT). Ported nearly line for line; changes: reversed smoothsteps
// (undefined in GLSL, and the projector's GPU cares) written as 1 - smoothstep, time in
// beats, the mouse light is a light circling the surface, and the beat adds a sparkle
// flash on the kick and a ring of flashes running out from the centre.
// Params are p_* uniforms; ranges and defaults are in sequin.json.
uniform float p_density, p_speed, p_tiltamt, p_sparkle, p_shimmer, p_punch, p_ring,
              p_roam, p_roamspeed, p_tint, p_hue, p_sat, p_bright, p_vignette, p_follow;

#define PI 3.14159265359
#define TAU 6.28318530718
#define SQRT3 1.7320508

float hash21(vec2 p) {
  p = fract(p * vec2(233.34, 851.73));
  p += dot(p, p + 23.45);
  return fract(p.x * p.y);
}
vec2 hash22(vec2 p) {
  float n = hash21(p);
  return vec2(n, hash21(p + n * 47.0));
}

// Hex tiling: xy = local coords in the cell, zw = cell id.
vec4 hexTile(vec2 p, float scale) {
  p *= scale;
  vec2 s = vec2(1.0, SQRT3);
  vec2 halfS = s * 0.5;
  vec2 aBase = floor(p / s);
  vec2 aLocal = mod(p, s) - halfS;
  vec2 pOff = p - halfS;
  vec2 bBase = floor(pOff / s);
  vec2 bLocal = mod(pOff, s) - halfS;
  float pick = step(dot(aLocal, aLocal), dot(bLocal, bLocal));
  return vec4(mix(bLocal, aLocal, pick), mix(bBase + vec2(0.5), aBase, pick));
}

// Five interfering waves, as in the original.
float waveField(vec2 c, float t) {
  float w = 0.0;
  w += sin(dot(c, vec2(0.7, 0.5)) * 3.5 - t * 2.8) * 0.35;
  w += sin(c.x * 4.2 + t * 1.9) * 0.25;
  float r1 = length(c - vec2(-0.3, 0.2));
  w += sin(r1 * 6.0 - t * 3.2) * 0.2 * (1.0 - smoothstep(0.0, 1.2, r1));
  w += sin(dot(c, vec2(-0.4, 0.8)) * 2.8 - t * 1.5) * 0.2;
  float r2 = length(c - vec2(0.4, -0.3));
  w += sin(r2 * 5.0 - t * 2.4) * 0.15 * (1.0 - smoothstep(0.0, 1.0, r2));
  // The beat: a ring running out from the centre, tilting the sequins it passes.
  float rr = length(c);
  w += p_ring * exp(-pow((rr - u_frac * 1.6) * 7.0, 2.0)) * (1.0 - u_frac);
  return w;
}

vec3 discNormal(float tiltAngle, float tiltDir) {
  float st = sin(tiltAngle);
  return vec3(st * cos(tiltDir), st * sin(tiltDir), cos(tiltAngle));
}

// Recolour the original's copper and gold, keeping their brightness.
vec3 tintc(vec3 c) {
  float lum = dot(c, vec3(0.299, 0.587, 0.114));
  vec3 t = hsv(mix(p_hue, u_hue, p_follow), p_sat * (1.0 - 0.5 * smoothstep(0.6, 1.0, lum)), lum * 1.15);
  return mix(c, t, p_tint);
}

vec3 content(vec2 uv0) {
  // The original's coordinates: centred, shorter side = 1, y up.
  vec2 uv = (uv0 - 0.5) * vec2(u_aspect, 1.0) / min(u_aspect, 1.0);
  uv.y = -uv.y;
  float t = u_beat * p_speed;
  float k = kick();

  vec4 hex = hexTile(uv, p_density);
  vec2 localPos = hex.xy;
  vec2 cellId = hex.zw;

  vec2 rnd = hash22(cellId);
  float sizeVar = 0.85 + rnd.x * 0.3;
  float baseTilt = (rnd.y - 0.5) * 0.15;
  float reflVar = 0.7 + rnd.x * 0.3;
  float phaseOff = rnd.y * TAU;

  float discRadius = 0.42 * sizeVar;
  float dist = length(localPos);
  float disc = 1.0 - smoothstep(discRadius - 0.06, discRadius, dist);
  float bevel = (1.0 - smoothstep(discRadius - 0.04, discRadius, dist))
              - (1.0 - smoothstep(discRadius - 0.08, discRadius - 0.04, dist));

  vec2 worldPos = cellId / p_density;
  float wave = waveField(worldPos, t);
  float shimmer = sin(t * 3.0 + phaseOff) * 0.04 * p_shimmer;
  float tiltAngle = (wave * 0.85 + baseTilt + shimmer) * p_tiltamt;
  float waveH = waveField(worldPos + vec2(0.01, 0.0), t);
  float waveV = waveField(worldPos + vec2(0.0, 0.01), t);
  float tiltDir = atan(waveV - wave, waveH - wave);
  vec3 N = discNormal(tiltAngle, tiltDir);

  // Main light from the upper right, slightly behind the viewer; tight mirror highlight
  // plus a broader sheen.
  vec3 L = normalize(vec3(0.4, 0.6, 0.9));
  vec3 R = reflect(-L, N);
  float rv = max(R.z, 0.0);
  float spec = (pow(rv, 48.0) + pow(rv, 8.0) * 0.15) * reflVar * p_sparkle * (1.0 + p_punch * k);

  // The roaming light (the original's mouse light), circling the surface in beats.
  if (p_roam > 0.0) {
    float ra = TAU * u_beat * p_roamspeed / 16.0;
    vec2 mUV = vec2(0.45 * cos(ra) * max(u_aspect, 1.0) / min(u_aspect, 1.0), 0.3 * sin(ra * 1.3));
    float mDist = length(worldPos - mUV);
    vec3 mL = normalize(vec3(mUV - worldPos, 0.5));
    float mS = pow(max(reflect(-mL, N).z, 0.0), 32.0);
    spec += mS * exp(-mDist * mDist * 6.0) * 1.5 * p_roam * reflVar;
  }

  vec3 darkSequin = tintc(vec3(0.02, 0.015, 0.01));
  vec3 copperMid  = tintc(vec3(0.78, 0.58, 0.42));
  vec3 amberFlash = tintc(vec3(1.0, 0.82, 0.55));
  vec3 hotGold    = tintc(vec3(1.0, 0.92, 0.72));

  float facing = clamp(cos(tiltAngle) * 0.5 + 0.5, 0.0, 1.0);
  vec3 sequinColor = mix(darkSequin, tintc(vec3(0.05, 0.035, 0.02)), facing * 0.6);
  sequinColor += copperMid * pow(facing, 3.0) * 0.2 * reflVar;
  sequinColor += copperMid * smoothstep(0.0, 0.3, spec) * 0.5;
  sequinColor += amberFlash * smoothstep(0.3, 0.8, spec) * 0.8;
  sequinColor += hotGold * smoothstep(0.7, 1.0, spec) * 1.2;
  sequinColor += copperMid * bevel * facing * 0.3;

  vec3 col = mix(tintc(vec3(0.012, 0.008, 0.005)), sequinColor, disc);

  float globalLight = 0.85 + 0.15 * dot(normalize(uv + vec2(0.0001)), vec2(0.4, 0.6));
  col *= globalLight;
  float vig = 1.0 - smoothstep(0.4, 1.3, length(uv));
  col *= mix(1.0, 0.6 + 0.4 * vig, p_vignette);
  col = pow(max(col, vec3(0.0)), vec3(0.93, 0.97, 1.04));
  // A soft lift for the projector, which crushes dark mids: darks and mids up about 2x, highlights eased, black stays black.
  return clamp((1.0 - exp(-col * p_bright * 2.6)) / (1.0 - exp(-2.6)), 0.0, 1.0);
}
