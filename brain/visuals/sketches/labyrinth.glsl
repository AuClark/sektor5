// Labyrinth: a first-person walk through a maze that never ends, and never stops giving hope.
//
// THE ROUTE is built from blocks. Block j is a straight heading north, then a straight of one
// unit east or west, so the path only ever gains ground to the north and can never cross
// itself. Both halves are closed forms, so the frame at any beat is found without walking the
// path from the start. The column of corner j is U * F(j), with F(odd) = 1 and F(even) 0 or 2,
// so every sideways straight is exactly one unit, left or right at random. The northern
// straights telescope, V(j) = U * (2 + G(j+1) - G(j)), so the arc length to corner j is
// U * (3j + G(j)). A unit is Bars bars of walking, so every corner lands on a downbeat. Only the
// six straights round the camera are ever built (gS/gD/gR), and everything is local to the
// current corner, so the numbers stay small at hour four.
//
// THE MAZE comes from the path. A face between two cells of one straight is open. A face
// between two route cells that are not neighbours on the route is shut. Every other face is open
// or shut by a hash of where it is in the world (Branch). That gives the side openings, alcoves
// and dead ends: the choices you did not take. Nothing can shut the route, and the camera stays
// on its centre line, so it never walks through a wall.
//
// THE RENDER is an exact grid walk (DDA) through cells, not a march. Walls are slabs on each
// shut face with a post on every corner, so inside a cell a ray can only stop where it crosses
// x = +-gA or z = +-gA in the direction it is going: two tests per cell. Which straights a cell
// belongs to is a pair of vec3 masks, carried from one cell to the next. Floor and roof are
// planes, hit exactly. The roof opens a panel at a time (Sky, and the reveal at the end of each
// phrase), and each open cell a ray crosses adds its shaft of light. Fireflies are one per cell,
// tested against the ray only in the cells it crosses. The next encounter is a few analytic
// shapes (ellipsoids, a plane, a cylinder) in the frame of the path where it stands.
//
// COST. SwiftShader (where the rig's budget is measured) runs every line of both sides of an if,
// and only skips further passes of a loop. So the worlds are data, not branches: walls, floor
// and roof are one material with per-world numbers, and one encounter is drawn per pixel. What
// costs is code, so it is kept short.
//
// HOPE. The light is always round the next corner: a lamp just past it that grows as you come up
// to the turn and moves on as you take it, lighting the far wall and the air. The haze goes to
// that light, not to grey. Ariadne's thread runs down the middle of the floor and round every
// turn, with a bead of light running ahead on the kick.
//
// Drivers (docs/reactive.md): A Hit -> the footfall, and the lamps, thread and fireflies flare;
// B Move -> fireflies sparkle, torches and threads flicker and sway, a glance; C Change -> the
// light ahead swells and the palette turns. The step forward lurches on every beat (Lurch), not
// on A, so the walk only ever goes forward. Params are p_* uniforms; see labyrinth.json.
uniform float p_pace, p_bars, p_lurch, p_bob, p_sway, p_fov,
              p_world, p_branch, p_height, p_thick, p_tex,
              p_hope, p_thread, p_motes, p_fog, p_sky, p_reveal,
              p_every, p_kinds, p_trip,
              p_steps, p_far,
              p_aband, p_aloop, p_ashape, p_aamt,
              p_bband, p_bloop, p_bshape, p_bamt,
              p_cband, p_cloop, p_cshape, p_camt,
              p_hue, p_follow, p_sat, p_bright, p_vign;

#define PI 3.1415927
#define TAU 6.2831853
#define EYE 0.44

// The six straights round the camera, as components of two vec3s each (straights 0-2 and 3-5):
// start cell (x, z), direction x (z is fixed: even straights run east-west, odd ones north), and
// arc length at the start. Picked out with one-hot dot products: SwiftShader is slow at indexing
// an array from a loop, and fast at dot().
vec3 gSxA, gSxB, gSzA, gSzB, gDxA, gDxB, gRA, gRB;
vec3 gX0, gX1, gZ0, gZ1, gX0b, gX1b, gZ0b, gZ1b;   // their cells, as two sets of three boxes
vec2 gOffm, gOc;              // the block's origin in the world (mod 1024), to key faces and cells
float gA, gBranch, gOpen;

// A hash with no sin in it: cheap enough for the inner loop, and the same on every GPU.
float h12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}
float G(float j) { return step(0.5, h12(vec2(mod(j, 2048.0), 7.31))); }
float F(float j) { return mod(j, 2.0) > 0.5 ? 1.0 : 2.0 * step(0.5, h12(vec2(mod(j, 2048.0), 3.17))); }

float vnoise(vec2 p) {
  vec2 i = floor(p), f = p - i;
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(h12(i), h12(i + vec2(1.0, 0.0)), f.x), mix(h12(i + vec2(0.0, 1.0)), h12(i + 1.0), f.x), f.y);
}

// atan to within a third of a degree, for the glow integrals.
float fatan(float x) {
  float a = abs(x);
  float r = a <= 1.0 ? a / (1.0 + 0.28125 * a * a) : 1.5707963 - a / (a * a + 0.28125);
  return sign(x) * r;
}

// Which of the six straights a cell is on: one flag per straight, in two vec3s.
vec3 maskA(vec2 c) { return step(gX0, vec3(c.x)) * step(vec3(c.x), gX1) * step(gZ0, vec3(c.y)) * step(vec3(c.y), gZ1); }
vec3 maskB(vec2 c) { return step(gX0b, vec3(c.x)) * step(vec3(c.x), gX1b) * step(gZ0b, vec3(c.y)) * step(vec3(c.y), gZ1b); }

// Whether the face between a cell (flags ma, mb) and its neighbour (na, nb) at key k is open.
float faceOpen(vec3 ma, vec3 mb, vec3 na, vec3 nb, vec2 k) {
  float same = dot(ma, na) + dot(mb, nb);
  float pc = step(0.5, dot(ma + mb, vec3(1.0))), pn = step(0.5, dot(na + nb, vec3(1.0)));
  vec2 kw = mod(k + gOffm, 1024.0);
  // Now and then the route runs through a hall: most side faces open, a colonnade of posts.
  float hall = step(h12(vec2(floor(kw.y / 14.0), 9.1)), 0.22);
  float open = step(h12(kw + 0.37), mix(gBranch * (0.5 + 0.5 * max(pc, pn)), 0.92, hall)) * (1.0 - pc * pn);
  return max(step(0.5, same), open);
}

void setupPath(float j, float U) {
  float g0 = G(j), g1 = G(j + 1.0), g2 = G(j + 2.0), g3 = G(j + 3.0);
  float V0 = U * (2.0 + g1 - g0), V1 = U * (2.0 + g2 - g1), V2 = U * (2.0 + g3 - g2);
  float fm = F(j - 1.0), f0 = F(j), f1 = F(j + 1.0), f2 = F(j + 2.0);
  float dp = sign(f0 - fm), d0 = sign(f1 - f0), d1 = sign(f2 - f1);
  gSxA = vec3(-dp * U, 0.0, 0.0);  gSxB = vec3(d0 * U, d0 * U, (d0 + d1) * U);
  gSzA = vec3(0.0, 0.0, V0);       gSzB = vec3(V0, V0 + V1, V0 + V1);
  gDxA = vec3(dp, 0.0, d0);        gDxB = vec3(0.0, d1, 0.0);
  gRA = vec3(-U, 0.0, V0);         gRB = vec3(V0 + U, V0 + U + V1, V0 + 2.0 * U + V1);
  // The boxes of cells, with a quarter-cell margin so integer cells test cleanly.
  float x0 = -dp * U, x2 = d0 * U, x4 = (d0 + d1) * U;
  gX0 = vec3(min(x0, 0.0), 0.0, min(0.0, x2)) - 0.25;
  gX1 = vec3(max(x0, 0.0), 0.0, max(0.0, x2)) + 0.25;
  gZ0 = vec3(0.0, 0.0, V0) - 0.25;
  gZ1 = vec3(0.0, V0, V0) + 0.25;
  gX0b = vec3(x2, min(x2, x4), x4) - 0.25;
  gX1b = vec3(x2, max(x2, x4), x4) + 0.25;
  gZ0b = vec3(V0, V0 + V1, V0 + V1) - 0.25;
  gZ1b = vec3(V0 + V1, V0 + V1, V0 + V1 + V2) + 0.25;
}

vec2 pickS(vec3 a, vec3 b) { return vec2(dot(a, gSxA) + dot(b, gSxB), dot(a, gSzA) + dot(b, gSzB)); }
vec2 pickD(vec3 a, vec3 b) { return vec2(dot(a, gDxA) + dot(b, gDxB), a.y + b.x + b.z); }

// Where the route is at arc length r from this block's corner, and which way it heads. Each
// corner is rounded into a quarter circle of radius 1/2 for the feet (w = 0.5); the head uses a
// wider, eased turn (w > 0.5) so it leans into the corner before the feet get there.
vec2 pathQ(float r, float w, out vec2 dir) {
  vec3 sa = step(gRA, vec3(r)), sb = step(gRB, vec3(r));
  sa.x = 1.0;
  vec3 oa = sa - vec3(sa.yz, sb.x), ob = sb - vec3(sb.yz, 0.0);    // which straight r is on
  dir = pickD(oa, ob);
  vec2 p = pickS(oa, ob) + dir * (r - dot(oa, gRA) - dot(ob, gRB));
  vec3 ua = (r - gRA + w) / (2.0 * w), ub = (r - gRB + w) / (2.0 * w);
  vec3 ka = step(0.0, ua) * step(ua, vec3(1.0)) * vec3(0.0, 1.0, 1.0), kb = step(0.0, ub) * step(ub, vec3(1.0));
  if (dot(ka + kb, vec3(1.0)) > 0.5) {                               // in a corner's turn
    vec2 co = pickD(ka, kb), ci = pickD(vec3(ka.yz, kb.x), vec3(kb.yz, 0.0));
    float u = dot(ka, ua) + dot(kb, ub);
    float a = (w > 0.55 ? smoothstep(0.0, 1.0, u) : u) * PI * 0.5;
    float ca = cos(a), sn = sin(a);
    p = pickS(ka, kb) + 0.5 * (co - ci) - 0.5 * co * ca + 0.5 * ci * sn;
    dir = ci * ca + co * sn;
  }
  return p;
}

// How far the roof panel over cell c has slid open, 0..1.
float roofOpen(vec2 c) {
  return clamp((gOpen * 1.1 - h12(mod(c + gOc, 1024.0) + vec2(0.71, 0.29))) * 7.0, 0.0, 1.0);
}

// The light a ray gathers passing a lamp at L, up to distance T.
float airGlow(vec3 ro, vec3 rd, vec3 L, float T, float e) {
  vec3 w = L - ro;
  float b = dot(w, rd);
  float k = sqrt(max(dot(w, w) - b * b, 0.0) + e);
  return (fatan((T - b) / k) + fatan(b / k)) / k;
}

// A lamp's light on a surface at p facing n, wrapped a little so the far side is not black.
vec3 lamp(vec3 p, vec3 n, vec3 lp, vec3 lc) {
  vec3 l = lp - p;
  float d2 = dot(l, l);
  return lc * (max(dot(n, l) * inversesqrt(d2 + 1e-4) + 0.15, 0.0) / 1.15) / (1.0 + 0.5 * d2);
}

// Ray against an ellipsoid of radii r at c: t (or 1e5) and the normal.
float ellip(vec3 ro, vec3 rd, vec3 c, vec3 r, out vec3 n) {
  vec3 o = (ro - c) / r, d = rd / r;
  float a = dot(d, d), b = dot(o, d), h = b * b - a * (dot(o, o) - 1.0);
  float t = (-b - sqrt(max(h, 0.0))) / a;
  n = normalize((o + d * t) / r);
  return h > 0.0 && t > 0.0 ? t : 1e5;
}

// What encounter n is, within Kinds: 0 mushrooms, 1 lantern, 2 orb, 3 door of light,
// 4 portcullis, 5 curtain of threads, 6 fallen pillar.
float kindOf(float n, float set) {
  float h = h12(vec2(mod(n, 2048.0), 5.5));
  if (set < 0.5) return mod(floor(h * 8.0), 7.0);    // anything; mushrooms twice as often
  if (set < 1.5) return 0.0;
  if (set < 2.5) return 1.0 + floor(h * 2.999);
  if (set < 3.5) return 4.0 + floor(h * 2.999);
  return 1.0 + floor(h * 5.999);
}

// drive() from COMMON, exactly, for one slot, with the band picked by a dot product and the
// Follow sample (the live level now, wNow) shared by all three slots: on SwiftShader the wave
// lookups and the if-chains are most of what drive() costs, and there are three of them.
float slot(float bd, float rate, float shape, float amt, vec4 wNow, float bb) {
  float L = loopBeats(rate);
  float ph = fract(bb / L), n = floor(bb / L);
  vec4 sel = vec4(step(3.5, bd) * (1.0 - step(4.5, bd)), step(0.5, bd) * (1.0 - step(1.5, bd)),
                  step(1.5, bd) * (1.0 - step(2.5, bd)), step(2.5, bd) * (1.0 - step(3.5, bd)));
  float hit = max(dot(wave(n * L + 0.15), sel), dot(wave(n * L + 0.55), sel));
  float fol = dot(wNow, sel);
  if (bd < 0.5) { hit = 1.0; fol = 1.0; }
  if (bd >= 4.5) { hit = u_energy; fol = u_energy; }
  float v = shape < 0.5 ? fol : hit * (shape < 1.5 ? exp(-5.0 * ph * max(L, 1.0)) : (shape < 2.5 ? ph
          : (shape < 3.5 ? 0.5 - 0.5 * cos(6.2831 * ph) : (shape < 4.5 ? step(ph, 0.5) : hash(vec2(n, bd))))));
  return amt * clamp(v, 0.0, 1.0);
}

vec3 content(vec2 uv) {
  float bb = barBeat();
  vec4 wNow = wave(u_beat);
  float A = slot(p_aband, p_aloop, p_ashape, p_aamt, wNow, bb);   // Hit    -> footfall, flares
  float B = slot(p_bband, p_bloop, p_bshape, p_bamt, wNow, bb);   // Move   -> sparkle, flicker, a glance
  float C = slot(p_cband, p_cloop, p_cshape, p_camt, wNow, bb);   // Change -> the light ahead, palette
  float world = floor(p_world + 0.5);
  float isH = step(world, 0.5), isS = step(abs(world - 1.0), 0.5), isN = step(abs(world - 2.0), 0.5),
        isP = step(abs(world - 3.0), 0.5), isT = step(3.5, world);

  // ---- The walk ---------------------------------------------------------------------------
  float bars = max(1.0, floor(p_bars + 0.5));
  float U = max(2.0, floor(p_pace * 4.0 * bars + 0.5));     // cells in a unit (Bars bars)
  float pace = U / (4.0 * bars);                             // cells per beat, snapped: corners land on bars
  float fb = floor(bb), fr = bb - fb;
  float ez = (1.0 - exp(-7.0 * fr)) / (1.0 - exp(-7.0));
  float sC = (fb + mix(fr, ez, clamp(p_lurch, 0.0, 1.0))) * pace;   // where the feet are
  float q = sC / U;
  float j = floor(q / 3.0);
  if (q < 3.0 * j + G(j)) j -= 1.0;
  float S0 = U * (3.0 * j + G(j));
  vec2 O = vec2(U * F(j), U * (2.0 * j + G(j)));
  setupPath(j, U);
  gOffm = mod(2.0 * O, 1024.0);
  gOc = mod(O, 1024.0);
  float rC = sC - S0;

  // ---- The phrase: close and dim, then a light ahead, then the roof opens ------------------
  float PL = p_reveal < 1.5 ? 16.0 : (p_reveal < 2.5 ? 32.0 : 64.0);
  float ph = fract(bb / PL);
  float arc = max(smoothstep(0.08, 0.72, ph), 1.0 - smoothstep(0.0, 0.08, ph));
  float rev = step(0.5, p_reveal) * max(smoothstep(0.64, 0.86, ph), 1.0 - smoothstep(0.0, 0.07, ph));
  if (u_scene > 6.5) rev = max(rev, smoothstep(0.0, 2.0, u_since) * (1.0 - smoothstep(24.0, 32.0, u_since)));
  gOpen = max(p_sky, 0.85 * rev);

  // ---- The next encounter, and the trip -----------------------------------------------------
  float EB = p_every < 0.5 ? 0.0 : 4.0 * (p_every < 1.5 ? 2.0 : (p_every < 2.5 ? 4.0 : 8.0));
  float set = floor(p_kinds + 0.5);
  float n1 = floor(bb / max(EB, 1.0)) + 1.0;
  // Every mushroom eaten keeps you tripping for eight bars.
  float trip = 0.0, eat = 99.0;       // eat: beats since the last mushrooms were eaten
  for (int k = 1; k < 5; k++) {
    float nk = n1 - float(k), e = bb - nk * EB;
    if (kindOf(nk, set) < 0.5) {
      trip = max(trip, smoothstep(0.0, 3.0, e) * (1.0 - smoothstep(24.0, 32.0, e)));
      eat = min(eat, e);
    }
  }
  if (EB < 0.5) eat = 99.0;
  trip *= p_trip * step(0.5, EB);
  trip = max(trip, isT * (0.6 + 0.25 * sin(bb * TAU / 32.0)));
  float Hw = p_height * (1.0 + 0.2 * trip * (0.5 + 0.5 * sin(bb * TAU / 16.0)));
  gA = 0.5 - clamp(p_thick, 0.05, 0.32) - 0.05 * trip * (0.5 + 0.5 * sin(bb * TAU / 4.0 + 1.0));
  gBranch = clamp(p_branch, 0.0, 1.0) * 0.8;

  // ---- The worlds, as numbers ---------------------------------------------------------------
  // Walls: dark and light albedo, course height and brick length, joint darkness, leaf noise
  // (instead of per-block tint), edge lines. Floor and roof: albedo, tile size, joints, noise.
  vec3 wD, wL, fD, fL, cD, hope, thr, mote, skyC, amb, edgeC;
  float wRow, wBr, wJ, wN, wE, fT, fJ, fN, fE;
  if (world < 0.5) {           // hedge maze at dusk: clipped yew, gravel, fireflies, dusk sky
    wD = vec3(0.025, 0.07, 0.025); wL = vec3(0.12, 0.36, 0.1); wRow = 1.0; wBr = 1.0; wJ = 0.0; wN = 1.0; wE = 0.0;
    fD = vec3(0.12, 0.11, 0.1); fL = vec3(0.3, 0.28, 0.25); fT = 1.0; fJ = 0.0; fN = 1.0; fE = 0.0;
    cD = vec3(0.01, 0.035, 0.012); hope = vec3(1.0, 0.8, 0.52); thr = vec3(1.0, 0.82, 0.4);
    mote = vec3(0.75, 1.0, 0.35); skyC = vec3(0.16, 0.17, 0.45); amb = vec3(0.08, 0.1, 0.14); edgeC = vec3(0.0);
  } else if (world < 1.5) {    // stone labyrinth: ashlar, flagstones, torches, a red thread
    wD = vec3(0.24, 0.2, 0.17); wL = vec3(0.42, 0.37, 0.31); wRow = 0.2; wBr = 0.42; wJ = 0.55; wN = 0.0; wE = 0.0;
    fD = vec3(0.17, 0.15, 0.13); fL = vec3(0.3, 0.27, 0.23); fT = 0.5; fJ = 0.6; fN = 0.0; fE = 0.0;
    cD = vec3(0.13, 0.11, 0.1); hope = vec3(1.0, 0.62, 0.3); thr = vec3(1.0, 0.08, 0.04);
    mote = vec3(1.0, 0.55, 0.2); skyC = vec3(0.3, 0.42, 0.75); amb = vec3(0.012, 0.01, 0.009); edgeC = vec3(0.0);
  } else if (world < 2.5) {    // neon grid: black glass, glowing edges, a synthwave sun
    wD = vec3(0.006, 0.005, 0.012); wL = vec3(0.03, 0.02, 0.06); wRow = 1.0; wBr = 1.0; wJ = 0.0; wN = 0.3; wE = 1.6;
    fD = vec3(0.004, 0.003, 0.008); fL = vec3(0.02, 0.015, 0.035); fT = 1.0; fJ = 0.0; fN = 0.3; fE = 0.6;
    cD = vec3(0.004); hope = vec3(1.0, 0.25, 0.55); thr = vec3(0.15, 0.95, 1.0);
    mote = vec3(1.0, 0.45, 0.95); skyC = vec3(0.14, 0.0, 0.3); amb = vec3(0.006, 0.004, 0.012); edgeC = vec3(0.1, 0.8, 1.0);
  } else if (world < 3.5) {    // ink on paper: a drawing, lit only by where the hatching is not
    wD = vec3(0.95, 0.92, 0.84); wL = wD; wRow = 0.25; wBr = 0.5; wJ = 0.0; wN = 0.0; wE = 0.0;
    fD = vec3(0.9, 0.86, 0.77); fL = fD; fT = 1.0; fJ = 0.0; fN = 0.0; fE = 0.0;
    cD = vec3(0.9, 0.87, 0.8); hope = vec3(1.0, 0.82, 0.45); thr = vec3(0.85, 0.08, 0.06);
    mote = vec3(1.0, 0.7, 0.3); skyC = vec3(0.98, 0.96, 0.9); amb = vec3(0.35, 0.34, 0.33); edgeC = vec3(0.0);
  } else {                     // the mushroom trip: op-art walls, spores, always tripping
    wD = vec3(0.1, 0.03, 0.14); wL = vec3(0.5, 0.1, 0.5); wRow = 1.0; wBr = 1.0; wJ = 0.0; wN = 0.6; wE = 0.3;
    fD = vec3(0.05, 0.02, 0.07); fL = vec3(0.2, 0.06, 0.25); fT = 0.5; fJ = 0.3; fN = 0.0; fE = 0.0;
    cD = vec3(0.05, 0.02, 0.08); hope = vec3(1.0, 0.5, 0.8); thr = vec3(0.4, 1.0, 0.5);
    mote = vec3(0.6, 1.0, 0.9); skyC = vec3(0.12, 0.05, 0.35); amb = vec3(0.02, 0.008, 0.035); edgeC = vec3(1.0, 0.5, 0.2);
  }
  // The dark worlds' fill light, raised for the projector: walls away from a lamp read as stone, not black.
  amb *= mix(3.5, 1.0, step(0.05, dot(amb, vec3(0.333))));
  // Hue and Follow turn the lights; the walls keep their world. Hue 0 with Follow 0 is the
  // world's own light. The trip blooms everything toward the show's colour.
  float hue = p_hue + u_hue * p_follow + 0.12 * C;
  float hmix = max(clamp(p_follow, 0.0, 1.0) * 0.75, step(0.004, fract(p_hue)) * 0.7) * (0.3 + 0.7 * p_sat);
  hope = mix(hope, hsv(fract(hue), 0.25 + 0.55 * p_sat, 1.0), hmix);
  thr = mix(thr, hsv(fract(hue + 0.5), 0.35 + 0.6 * p_sat, 1.0), clamp(p_follow, 0.0, 1.0) * 0.4 * (1.0 - isP));
  mote = mix(mote, hsv(fract(hue + 0.08), 0.6, 1.0), hmix * 0.6);
  vec3 tripC = hsv(fract(p_hue + u_hue + 0.1 * sin(bb * TAU / 32.0)), 0.8, 1.0);
  hope = mix(hope, tripC, 0.45 * trip);
  vec3 fogC = mix(mix(hope * 0.8, vec3(0.25, 0.3, 0.55), 0.45 * isH + 0.25 * isN), mix(wD, hope, 0.3), isP);

  // ---- The next encounter's place, and the two lamps round the corners ahead ---------------
  // One pass over the corners: the first two still ahead carry the lamps, and the encounter is
  // stepped back a cell if it would land on one.
  float rI = n1 * EB * pace - S0;
  // The last encounter was stepped back a cell if it fell on a corner, so it was reached a cell
  // early: move the moment of eating to match.
  float rP = rI - EB * pace;
  vec3 pA = step(abs(rP - gRA), vec3(0.75)), pB = step(abs(rP - gRB), vec3(0.75));
  eat += dot(pA + pB, vec3(1.0)) > 0.5 ? 1.0 / pace : 0.0;
  vec3 nA = step(abs(rI - gRA), vec3(0.75)) * vec3(0.0, 1.0, 1.0), nB = step(abs(rI - gRB), vec3(0.75));
  if (dot(nA + nB, vec3(1.0)) > 0.5) rI = dot(nA, gRA) + dot(nB, gRB) - 1.0;   // off the corners
  vec3 okA = step(vec3(-0.9), gRA - rC) * vec3(0.0, 1.0, 1.0), okB = step(vec3(-0.9), gRB - rC);
  vec3 k1A = vec3(0.0, okA.xy), k1B = vec3(okA.z, okB.xy), k2A = vec3(0.0, 0.0, okA.x), k2B = vec3(okA.yz, okB.x);
  vec3 f0A = okA - k1A, f0B = okB - k1B, f1A = k1A - k2A, f1B = k1B - k2B;   // the first two corners ahead
  vec2 lp0 = pickS(f0A, f0B), ld0 = pickD(f0A, f0B), lp1 = pickS(f1A, f1B), ld1 = pickD(f1A, f1B);
  float lr0 = dot(f0A, gRA) + dot(f0B, gRB) + 60.0 * (1.0 - dot(f0A + f0B, vec3(1.0)));
  float lr1 = dot(f1A, gRA) + dot(f1B, gRB) + 60.0 * (1.0 - dot(f1A + f1B, vec3(1.0)));
  vec3 Lp[3], Lc[3];
  vec2 hd, dcam, dI;
  vec2 pc = pathQ(rC, 0.5, dcam);
  vec2 hpos = pathQ(bb * pace - S0, 0.75, hd);
  vec2 pI = pathQ(rI, 0.5, dI);

  // ---- The camera --------------------------------------------------------------------------
  float yaw = p_sway * (0.1 * sin(bb * TAU / 16.0) + 0.06 * B * sin(bb * 1.7));
  hd = vec2(hd.x * cos(yaw) - hd.y * sin(yaw), hd.x * sin(yaw) + hd.y * cos(yaw));
  vec2 rt = vec2(hd.y, -hd.x);
  pc += rt * p_bob * 0.014 * sin(bb * PI);                  // weight from foot to foot
  float fall = clamp(A, 0.0, 1.0) * exp(-4.0 * fr);        // the footfall
  vec3 ro = vec3(pc.x, EYE - p_bob * 0.05 * fall + 0.01 * p_bob * cos(bb * TAU), pc.y);
  vec2 sp = (uv - 0.5) * vec2(u_aspect, 1.0);
  sp.y = -sp.y;
  sp /= max(1.0, 0.9 / u_aspect);                           // tall surfaces: keep the corridor wide enough
  // The trip breathes the middle of the view and leaves the frame edge where it is, so nothing
  // bends into rings at the border.
  float wk = trip * (1.0 - smoothstep(0.1, 0.62, length(sp)));
  sp *= 1.0 + wk * (0.1 * sin(bb * TAU / 8.0) + 0.05 * A);
  sp += wk * 0.035 * vec2(sin(sp.y * 4.0 + bb * 0.8), sin(sp.x * 3.5 - bb * 0.6));
  float fk = 1.25 * p_fov * (1.0 + 0.15 * trip * sin(bb * TAU / 8.0));
  float pitch = -0.05 + 0.3 * rev;
  vec3 fw = vec3(hd.x, 0.0, hd.y), rt3 = vec3(rt.x, 0.0, rt.y);
  vec3 up = vec3(0.0, cos(pitch), 0.0) - fw * sin(pitch);
  vec3 rd = normalize(fw * cos(pitch) + vec3(0.0, sin(pitch), 0.0) + (sp.x * rt3 + sp.y * up) * fk);
  float px = u_px * fk;

  // ---- The lamps ---------------------------------------------------------------------------
  // Each grows as you come up to its turn; as you take it, it retreats and fades and the next
  // one takes over. It is never reached.
  float dc0 = lr0 - rC, dc1 = lr1 - rC;
  vec2 dcs = vec2(dc0, dc1);
  vec2 I2 = mix(vec2(0.35), vec2(1.6), smoothstep(10.0, 0.5, dcs)) * smoothstep(-0.9, 0.4, dcs) * step(dcs, vec2(40.0));
  I2.y *= 1.0 - smoothstep(-0.9, 1.2, dc0);
  vec2 back = 1.4 + 2.2 * (1.0 - smoothstep(-0.9, 0.7, dcs));
  vec3 lampC = hope * p_hope * (0.5 + 0.5 * arc) * (1.0 + 0.8 * C + 0.5 * A) * 3.0;
  float lh = 0.6 * min(Hw, 1.6);
  Lp[0] = vec3(lp0.x + ld0.x * back.x, lh, lp0.y + ld0.y * back.x); Lc[0] = lampC * I2.x;
  Lp[1] = vec3(lp1.x + ld1.x * back.y, lh, lp1.y + ld1.y * back.y); Lc[1] = lampC * I2.y;
  // The encounter: always the next one, which fades in as the last is reached and is gone by the
  // time you get to it (eaten, lifted, parted, passed under or burst into light).
  dI = normalize(dI);
  float kind = EB > 0.0 && rI < gRB.z ? kindOf(n1, set) : -1.0;
  float dist = rI - rC;
  float appear = smoothstep(0.0, 2.0, bb - (n1 - 1.0) * EB) * step(-0.05, dist) * step(-0.5, kind);
  float isM = step(kind, 0.5), isL = step(abs(kind - 1.0), 0.5), isO = step(abs(kind - 2.0), 0.5);
  float yI = isL * min(0.78 * Hw, Hw - 0.22) + isO * (EYE + 0.03 + 0.5 * (1.0 - smoothstep(0.0, 2.0, dist))) + isM * 0.12;
  // Mushrooms, per world: the cap (deep and saturated) and the glow of the gills and spots.
  //   hedge and paper: fly agaric, a red cap, gills glowing gold; stone: ghost fungus, a deep
  //   teal cap with electric cyan gills; neon: violet with cyan; the trip: the show's colours.
  vec3 capC = (isH + isP) * vec3(0.7, 0.02, 0.015) + isS * vec3(0.01, 0.07, 0.1) + isN * vec3(0.16, 0.01, 0.35)
            + isT * hsv(fract(p_hue + u_hue + 0.55), 0.9, 0.45);
  vec3 mushC = (isH + isP) * vec3(1.0, 0.5, 0.06) + isS * vec3(0.2, 1.0, 1.0) + isN * vec3(0.25, 0.95, 1.0) + isT * tripC;
  vec3 iC = isM * mushC
          + isL * mix(vec3(1.0, 0.5, 0.18), hope, 0.3) * 1.3 + isO * mix(vec3(0.6, 0.85, 1.0), hope, 0.35) * 1.2
          + step(abs(kind - 3.0), 0.5) * mix(vec3(1.0, 0.95, 0.8), hope, 0.4);
  Lp[2] = vec3(pI.x, yI, pI.y);
  float preEat = isM * appear * smoothstep(1.4, 0.15, dist);      // the glow flares just before you eat them
  float mpulse = 1.0 + 0.35 * A + 1.2 * preEat;
  Lc[2] = iC * (1.0 - 0.45 * (isS + isN) * isM) * (1.0 - 0.3 * isM * (1.0 - smoothstep(-0.05, 0.6, dist))) * (1.0 + 0.3 * isM) * (1.0 + exp(-abs(dist) * 3.0) + 0.4 * A) * mix(1.0, mpulse, isM) * appear * 0.4 * step(kind, 3.5);

  // ---- The grid walk -----------------------------------------------------------------------
  float FAR = p_far;
  vec2 ro2 = ro.xz, rd2 = rd.xz;
  if (abs(rd2.x) < 1e-5) rd2.x = 1e-5;
  if (abs(rd2.y) < 1e-5) rd2.y = 1e-5;
  vec2 sg = sign(rd2), inv = 1.0 / rd2;
  float tFl = rd.y < -1e-4 ? -ro.y / rd.y : 1e5;
  float tCe = rd.y > 1e-4 ? (Hw - ro.y) / rd.y : 1e5;
  float tLim = min(min(tFl, tCe), FAR);
  vec2 c = floor(ro2 + 0.5);
  vec3 ma = maskA(c), mb = maskB(c);
  float tIn = 0.0, tHit = 1e5, post = 0.0;
  vec2 nrm = vec2(0.0), hc = c;
  float steps = floor(p_steps + 0.5);
  vec3 glow = vec3(0.0), mglow = vec3(0.0);
  float shaft = 0.0, motes = clamp(p_motes, 0.0, 1.0);
  for (int i = 0; i < 48; i++) {
    if (float(i) >= steps) break;
    vec2 tA = (c + sg * gA - ro2) * inv;       // where the ray meets the wall faces in this cell
    vec2 tE = (c + sg * 0.5 - ro2) * inv;      // and where it leaves the cell
    float tOut = min(tE.x, tE.y);
    vec2 cx = c + vec2(sg.x, 0.0), cz = c + vec2(0.0, sg.y);
    vec3 xa = maskA(cx), xb = maskB(cx), za = maskA(cz), zb = maskB(cz);
    float ox = faceOpen(ma, mb, xa, xb, c + cx);
    float oz = faceOpen(ma, mb, za, zb, c + cz);
    float th = 1e5;
    float zl = abs(ro2.y + rd2.y * tA.x - c.y), xl = abs(ro2.x + rd2.x * tA.y - c.x);
    if (tA.x >= tIn - 1e-4 && tA.x <= tOut && (ox < 0.5 || zl > gA)) { th = tA.x; nrm = vec2(-sg.x, 0.0); post = ox; }
    if (tA.y >= tIn - 1e-4 && tA.y <= tOut && tA.y < th && (oz < 0.5 || xl > gA)) { th = tA.y; nrm = vec2(0.0, -sg.y); post = oz; }
    float tEnd = min(min(th, tOut), tLim);
    vec2 gc = mod(c + gOc, 1024.0);
    // Light pouring down through the roof panel over this cell, if it is open.
    float rh = h12(gc + vec2(0.71, 0.29));
    float hs = 0.5 * clamp((gOpen * 1.1 - rh) * 7.0, 0.0, 1.0);      // half-size of the opening
    vec2 s1 = (c - hs - ro2) * inv, s2 = (c + hs - ro2) * inv;
    vec2 sn = min(s1, s2), sx = max(s1, s2);
    shaft += max(min(min(sx.x, sx.y), tEnd) - max(max(sn.x, sn.y), tIn), 0.0) * (fract(rh * 13.7) > 0.4 ? 1.0 : 0.3);
    // A firefly in this cell, drifting up and on toward the light.
    float hm = h12(gc + 0.5);
    float ph1 = fract(hm * 7.0 + bb * 0.05);
    vec3 m = vec3(c.x + 0.6 * (fract(hm * 31.0) - 0.5), (0.15 + 0.8 * fract(hm * 13.0 + bb * (0.02 + 0.1 * rev))) * Hw, c.y - 0.35 + 0.7 * ph1);
    float tc = clamp(dot(m - ro, rd), tIn, tEnd);
    vec3 dv = ro + rd * tc - m;
    float r2 = max(0.018, tc * px * 2.2);
    r2 *= r2;
    float v = r2 / (dot(dv, dv) + r2);
    float tw = (abs(fract(bb * 0.5 + hm * 9.0) - 0.5) * 2.0 + 1.5 * rev) + 1.5 * B * step(0.6, fract(hm * 17.0 + floor(bb * 2.0) * 0.618));
    mglow += mote * (step(hm, motes) * smoothstep(0.2, 0.7, tc) * v * v * ph1 * (1.0 - ph1) * 4.0 * tw * (1.0 + A) * 1.6);
    if (th < tLim) { tHit = th; hc = c; break; }
    if (tOut > tLim) break;
    tIn = tOut;
    if (tE.x < tE.y) { c = cx; ma = xa; mb = xb; } else { c = cz; ma = za; mb = zb; }
  }

  // ---- What the ray hit: 0 wall, 1 floor, 2 roof, 3 the far light --------------------------
  float t = tHit < 1e4 ? tHit : (tLim >= FAR - 1e-3 ? FAR : (tFl < tCe ? tFl : tCe));
  float surf = tHit < 1e4 ? 0.0 : (tLim >= FAR - 1e-3 ? 3.0 : (tFl < tCe ? 1.0 : 2.0));
  float isW = step(surf, 0.5), isF = step(abs(surf - 1.0), 0.5), isC = step(abs(surf - 2.0), 0.5);
  vec3 p = ro + rd * t;
  float aa = t * px;                                        // one pixel, in world units, here
  float fade = (1.0 - smoothstep(0.008, 0.04, aa)) * p_tex; // fine texture fades with distance
  vec3 n3 = isW > 0.5 ? vec3(nrm.x, 0.0, nrm.y) : vec3(0.0, 1.0 - 2.0 * isC, 0.0);
  vec2 fc = floor(p.xz + 0.5), fl = p.xz - fc;
  vec2 gw = p.xz + gOc;
  float edgeF = max(abs(fl.x), abs(fl.y));
  float o = roofOpen(isW > 0.5 ? hc : fc);

  // One material for every surface of every world: courses of blocks with joints, a tint per
  // block or a leafy noise, and lines along the edges.
  float u = abs(nrm.x) > 0.5 ? gw.y : gw.x;
  vec2 st = isW > 0.5 ? vec2(u, p.y) : gw;
  vec2 key = isW > 0.5 ? mod(hc * 2.0 - nrm + gOffm, 1024.0) : vec2(3.7, 1.3);
  float rowH = isW > 0.5 ? wRow : fT, brW = isW > 0.5 ? wBr : fT;
  float row = floor(st.y / rowH);
  float bx = st.x / brW + 0.5 * mod(row, 2.0);
  vec2 bf = fract(vec2(bx, st.y / rowH));
  float dj = min(min(bf.x, 1.0 - bf.x) * brW, min(bf.y, 1.0 - bf.y) * rowH);
  float joint = smoothstep(0.012 + aa, 0.004, dj) * fade * (isW > 0.5 ? wJ : fJ);
  float nz = mix(0.5, vnoise(st * (isW > 0.5 ? 4.5 : 3.0) + key), fade);
  // Leaves on a hedge, pebbles on its path: a jittered cell of little ovals, lit from above.
  vec2 lq = st * (isW > 0.5 ? vec2(22.0, 28.0) : vec2(40.0));
  lq.x += 0.5 * mod(floor(lq.y), 2.0) + 0.6 * sin(lq.y * 0.37 + key.x);
  vec2 lf = fract(lq) - 0.5;
  float lfh = h12(floor(lq) + key);
  lf += (vec2(lfh, fract(lfh * 7.3)) - 0.5) * 0.25;
  float ca = cos(lfh * 6.0), sa2 = sin(lfh * 6.0);
  lf = vec2(ca * lf.x - sa2 * lf.y, sa2 * lf.x + ca * lf.y);
  float leaf = smoothstep(0.5, 0.2, length(lf * vec2(1.0, 1.5))) * (0.45 + 0.55 * clamp(0.5 - lf.y * 1.4, 0.0, 1.0)) * (0.4 + 0.8 * lfh);
  leaf = max(leaf, 0.7 * smoothstep(0.45, 0.2, length(fract(lq * 1.37 + 0.31) - 0.5)) * fract(lfh * 5.1));
  float leafy = mix(0.35, leaf, fade * (1.0 - smoothstep(0.004, 0.012, aa))) * (0.35 + 0.65 * smoothstep(0.2, 0.7, nz));
  float pat = mix(h12(vec2(floor(bx), row) + key), leafy, isW > 0.5 ? wN : fN);
  vec3 alb = isW > 0.5 ? mix(wD, wL, pat) : (isF > 0.5 ? mix(fD, fL, pat) : cD * (0.6 + 0.8 * pat));
  alb *= (1.0 - joint) * (1.0 + (0.4 * nz - 0.2) * fade * isS);
  alb *= 1.0 + isH * isW * 0.9 * smoothstep(Hw - 0.07, Hw, p.y);        // the clipped top of a hedge catches the sky
  // Edge lines: the top, foot and corners of a wall; the cell grid on floor and roof.
  float e1 = abs(abs(fract(u) - 0.5) - (0.5 - gA));
  float eW = min(min(abs(p.y - 0.02), abs(p.y - Hw + 0.02)), e1 + 0.004 * sin(p.y * 30.0 + floor(bb * 4.0) * 1.7) * isP);
  float eG = 0.5 - edgeF;
  float line = smoothstep(0.012 + aa, 0.003, isW > 0.5 ? eW : eG);
  vec3 emit = edgeC * line * (isW * wE + isF * fE * (1.0 - smoothstep(4.0, 14.0, t)) + isC * 0.4) * (1.0 + 0.8 * A);
  float ink = isP * (isW * max(line, 0.45 * smoothstep(0.004 + aa, 0.001, dj) * fade)
            + (1.0 - isW) * smoothstep(0.3, 0.45, abs(fract((gw.x + gw.y * (1.0 - 2.0 * isC)) * 14.0) - 0.5)) * fade * (1.0 - smoothstep(0.004, 0.012, aa))
              * mix(0.6, smoothstep(gA - 0.18, gA, edgeF), isF));
  // The trip paints the walls in rippling bands round the show's colour: the trip world always,
  // any other world while the mushrooms last.
  float band = fract(p.y * 2.2 + 0.25 * sin(u * 2.0 + bb * 0.4) + 0.12 * sin(u * 5.0 - p.y * 3.0 + bb * 0.9) + bb * 0.0625 + 0.15 * A);
  float bandK = isW * max(isT, 0.7 * trip * (1.0 - isP));
  vec3 bandC = hsv(fract(p_hue + u_hue + (floor(band * 3.0) - 1.0) * 0.12 + 0.08 * sin(u * 0.7 + bb * 0.2)), 0.85, 0.6);
  alb = mix(alb, bandC * mix(0.25, smoothstep(0.02, 0.1, abs(fract(band * 3.0) - 0.5)), fade) * mix(0.35, 1.0, isT), bandK * (0.3 + 0.7 * isT));
  // Torches: in the stone world, a flame in an iron sconce on some faces, lighting the wall round it.
  float ht = h12(key + 11.3);
  vec2 fq = vec2(fract(u + 0.5) - 0.5, p.y - 0.6 * min(Hw, 1.4));
  float fl2 = 0.8 + 0.2 * sin(bb * 11.0 + ht * 50.0) + 0.6 * B * h12(vec2(ht, floor(bb * 4.0)));
  float flame = smoothstep(0.03, 0.0, length(vec2(fq.x * (1.5 + 18.0 * max(fq.y, 0.0)), max(fq.y - 0.03, 0.0) * 0.5 + min(fq.y, 0.0))) - 0.014);
  float torch = isS * isW * (1.0 - post) * step(ht, 0.4);
  emit += vec3(1.0, 0.62, 0.22) * (flame * 3.0 + 2.0 * alb * exp(-dot(fq, fq) * 26.0)) * fl2 * torch;
  emit += isN * isW * (edgeC * 0.12 * exp(-p.y * 2.5) + hope * 0.14 * smoothstep(0.0, Hw, p.y)) * (1.0 + A);
  // In the hedge, a round paper lantern hung on some faces, with a warm pool round it.
  float lan = isH * isW * (1.0 - post) * step(ht, 0.3);
  emit += vec3(1.0, 0.7, 0.35) * (2.5 * smoothstep(0.045, 0.035, length(fq * vec2(1.0, 0.8))) + 0.35 * exp(-dot(fq, fq) * 9.0)) * fl2 * lan;
  alb *= 1.0 - 0.9 * torch * step(abs(fq.x), 0.03) * step(abs(fq.y + 0.06), 0.03);

  // A detail on some faces, in the world's own hand: a niche or a carved ring in the stone, a
  // patch of flowers in the hedge, a neon sign, a doodle on the paper, an eye in the trip.
  float hdc = h12(key + 5.7);
  float dec = isW * (1.0 - post) * step(hdc, 0.34) * step(0.4, ht) * fade;
  float shp = floor(fract(hdc * 17.3) * 3.0);
  vec2 wq = vec2(fq.x, p.y);
  float yn = 0.62 * min(Hw, 1.4);
  float dRing = abs(length(wq - vec2(0.0, yn)) - 0.11) - 0.012;
  float dArch = max(wq.y < yn ? abs(wq.x) - 0.13 : length(wq - vec2(0.0, yn)) - 0.13, 0.18 - wq.y);
  vec2 tq = wq - vec2(0.0, yn);
  float dTri = abs(max(abs(tq.x) * 0.866 + tq.y * 0.5, -tq.y) - 0.08) - 0.012;
  float dS = shp < 0.5 ? dArch : (shp < 1.5 ? dRing : dTri);
  float dline = smoothstep(0.012 + aa, 0.004, abs(dS)) * dec;
  float din = step(dS, 0.0) * dec;
  float flick = 0.75 + 0.25 * step(0.2, fract(bb * 1.7 + hdc * 9.0)) + 0.4 * A;
  vec3 signC = hsv(fract(hdc * 5.0 + 0.8 * step(0.5, fract(hdc * 3.1))), 0.8, 1.0);
  alb *= 1.0 - isS * (0.65 * din * step(shp, 0.5) + 0.45 * dline * step(0.5, shp));
  emit += isS * hope * 0.5 * dline * step(shp, 0.5) * step(yn, wq.y);            // the niche's lit rim
  vec2 fg = fract(wq * 16.0) - 0.5;
  float bloom = smoothstep(0.45, 0.2, length(fg)) * step(0.4, h12(floor(wq * 16.0) + key)) * smoothstep(0.34, 0.2, length(tq * vec2(0.8, 1.4)));
  emit += isH * dec * bloom * mix(vec3(1.0, 0.35, 0.6), vec3(1.0, 0.85, 0.4), step(0.5, fract(hdc * 7.7))) * 0.9;
  emit += (isN * signC * 1.6 * flick + isT * hsv(fract(hue + 0.5 + length(tq) * 2.0), 0.8, 1.0) * 1.2) * dline;
  ink = max(ink, isP * dline);

  // Where the roof is open: sky on the top of the walls, a pool of it on the floor, the opening.
  float sky = isW * max(o, 0.45 * isH) * smoothstep(0.35 * Hw, Hw, p.y)
            + isF * o * smoothstep(0.5 * o, 0.5 * o - 0.08, edgeF)
            + isC * smoothstep(0.5 * o, 0.5 * o - aa * 2.0 - 0.01, edgeF);
  emit += isC * hope * 0.6 * rev * smoothstep(0.5 * o - 0.1, 0.5 * o, edgeF) * step(0.01, o);

  // Ariadne's thread, down the middle of the route and round every corner, with a bead of light
  // running ahead of you on each kick. The straights, then the arc of whichever corner cell
  // this is in.
  vec3 fa = maskA(fc), fb2 = maskB(fc);
  float nf = dot(fa + fb2, vec3(1.0));
  vec2 td = pickD(fa, fb2);          // one straight: its direction; a corner: the sum of both
  // Arc length: along the straight, or the mean of the two straights' in a corner cell.
  float sb = (dot(fa, gRA + (p.x - gSxA) * gDxA + (p.z - gSzA) * vec3(0.0, 1.0, 0.0))
            + dot(fb2, gRB + (p.x - gSxB) * gDxB + (p.z - gSzB) * vec3(1.0, 0.0, 1.0))) / max(nf, 1.0);
  float best = nf > 0.5 ? abs(td.x * fl.y - td.y * fl.x) : 1e3;
  // A corner cell: round the quarter circle. The straight out is north when the corner is odd.
  float odd = mod(0.5 * (dot(fa, vec3(0.0, 1.0, 2.0)) + dot(fb2, vec3(3.0, 4.0, 5.0)) + 1.0), 2.0);
  vec2 w = fl - 0.5 * (odd > 0.5 ? 1.0 : -1.0) * vec2(-td.x, 1.0);
  if (nf > 1.5) best = abs(length(w) - 0.5);
  float ahead = sb - rC;
  float wth = 0.008 + aa * 0.6;
  float core = smoothstep(wth, wth * 0.3, best) * isF * p_thread;
  float halo = (exp(-best * best / (0.004 + aa * aa * 4.0)) + 0.35 * exp(-best * best / 0.03)) * isF * p_thread;
  float bead = exp(-(ahead - 0.6 - 5.0 * fr) * (ahead - 0.6 - 5.0 * fr) * 1.44) * (0.4 + A);
  emit += thr * (0.5 + 0.5 * smoothstep(-1.0, 4.0, ahead) + 2.0 * bead) * (1.0 + 0.6 * A) * (core * 1.6 + halo * 0.35) * (1.0 - isP);
  alb = mix(alb, thr * 0.9, core * isP);

  // Light: the lamps, the sky where it is open, the ambient.
  vec3 L = amb + lamp(p, n3, Lp[0], Lc[0]) + lamp(p, n3, Lp[1], Lc[1]) + lamp(p, n3, Lp[2], Lc[2]);
  // Bounce: the light ahead fills the whole corridor a little, so no near wall is a dead hole on
  // a projector; the thread lights the foot of the walls either side of it; dusk sky over hedges.
  float onRoute = step(0.5, dot(maskA(hc) + maskB(hc), vec3(1.0)));
  L += hope * p_hope * (0.1 + 0.08 * arc) * (isS + 0.5 * isH + 0.7 * isT + 0.3 * isP)
     + skyC * isH * (0.5 + 0.5 * n3.y)
     + thr * p_thread * 0.35 * isW * onRoute * exp(-p.y * 5.0) * (1.0 - isP);
  float aoF = 0.45 + 0.55 * mix(smoothstep(0.0, 0.3, p.y), smoothstep(gA, gA - 0.2, edgeF), isF);
  // Round a mushroom cluster the rest of the light drops away, so they are what lights the place.
  float darkK = isM * appear * smoothstep(2.0, 0.5, length(p.xz - pI));
  L = mix(L, amb * 0.4 + lamp(p, n3, Lp[2], Lc[2]), 0.7 * darkK);
  vec3 col = alb * (L + (skyC * 1.3 + hope * 0.8 * rev) * sky * (0.35 + 0.65 * rev) * (1.0 - isC))
           * (0.45 + 0.55 * mix(smoothstep(0.0, 0.3, p.y), smoothstep(gA, gA - 0.2, edgeF), isF)) + emit;
  // The sky through an opening: dusk to dawn toward the way you are going, stars over the hedges
  // and the trip, a striped sun over the grid, drawn rays over the paper.
  float el = clamp(rd.y, 0.0, 1.0);
  float toward = 0.5 + 0.5 * dot(normalize(rd.xz + 1e-5), hd);
  vec3 sc = mix(hope * (0.5 + 0.5 * toward), skyC, smoothstep(0.0, 0.8, el));
  vec2 ss = rd.xz / max(rd.y, 0.05) * 9.0;
  float star = step(0.9, h12(floor(ss))) * smoothstep(0.3, 0.0, length(fract(ss) - 0.5)) * (isH + isT + 0.3 * isS);
  sc += star * (0.6 + 0.4 * sin(bb * 3.0 + h12(floor(ss)) * 40.0));
  float sd = length(vec2(dot(normalize(rd.xz + 1e-5), rt), rd.y - 0.35));
  sc += isN * hope * 1.4 * smoothstep(0.3, 0.28, sd) * min(step(0.35, fract(rd.y * 22.0 - bb * 0.25)) + step(0.5, rd.y), 1.0);
  sc = mix(sc, hsv(fract(el * 1.5 + bb * 0.03 + toward * 0.3), 0.8, 1.0), 0.5 * trip * isT);
  sc = mix(sc, skyC, isP);
  ink = mix(ink, 0.7 * smoothstep(0.3, 0.42, abs(fract(dot(rd.xz, rt) / max(rd.y, 0.1) * 3.0) - 0.5)), isP * isC * sky);
  col = mix(col, sc * (0.7 + 0.9 * rev), isC * sky);

  // ---- The encounter -----------------------------------------------------------------------
  // In its own frame: x across the corridor, y up, z along the route, the item at the origin.
  vec2 r2 = vec2(dI.y, -dI.x);
  vec2 o2 = ro.xz - pI;
  vec3 lo = vec3(dot(o2, r2), ro.y, dot(o2, dI));
  vec3 ld = vec3(dot(rd.xz, r2), rd.y, dot(rd.xz, dI));
  float tS = t;
  float near = smoothstep(-0.05, 0.8, dist) * appear;
  // Round things: mushroom caps on their stems, a paper lantern on its string, an orb.
  // Only rays that enter the item's box need the pieces; the glow round them is one lookup.
  vec3 bx1 = (vec3(-0.5, -0.1, -0.6) - lo) / ld, bx2 = (vec3(0.5, Hw + 0.1, 0.6) - lo) / ld;
  vec3 bn = min(bx1, bx2), bxx = max(bx1, bx2);
  float bIn = step(max(max(max(bn.x, bn.y), bn.z), 0.0), min(min(min(bxx.x, bxx.y), bxx.z), tS));
  float nPieces = (isM * 3.0 + isL + isO) * bIn;
  glow += iC * appear * (0.02 * isM * mpulse * smoothstep(-0.05, 0.6, dist) * airGlow(lo, ld, vec3(0.0, 0.12, 0.0), tS, 0.05) + 0.012 * (isL + isO) * airGlow(lo, ld, vec3(0.0, yI, 0.0), tS, 0.036));
  float mushHit = 0.0;
  for (int k = 0; k < 3; k++) {
    if (float(k) >= nPieces) break;
    float fk = float(k), hk = h12(vec2(n1, fk + 1.3));
    // Three of them, a big one, a middling one and a small one, on one side, leaning together.
    float side = mod(n1, 2.0) < 0.5 ? -1.0 : 1.0;
    float sz = (0.15 - 0.04 * fk + 0.015 * hk) * smoothstep(-0.05, 0.6, dist) * appear * (1.0 + 0.2 * trip) * (1.0 + 0.04 * A);
    vec3 base = vec3(side * (gA - 0.1 - 0.05 * fk), 0.0, (fk - 1.0) * 0.26 + 0.05 * hk);
    float hst = sz * (1.25 + 0.5 * hk);
    float lean = -side * (0.1 + 0.08 * fk) + 0.05 * sin(bb * PI * 0.25 + fk);
    // Into the mushroom's own frame, tilted about its foot.
    vec3 mo = lo - base, md = ld;
    float cl = cos(lean), sl = sin(lean);
    mo.xy = vec2(cl * mo.x - sl * mo.y, sl * mo.x + cl * mo.y);
    md.xy = vec2(cl * md.x - sl * md.y, sl * md.x + cl * md.y);
    vec3 c1 = vec3(0.0, hst, 0.0), r1 = vec3(sz, sz * 0.5, sz);
    vec3 c2 = vec3(0.0, hst * 0.42, 0.0), r2e = vec3(sz * 0.2, hst * 0.52, sz * 0.2);   // a stem that bulges low and tapers up
    vec3 wo = lo, wd = ld;
    if (isL > 0.5) { mo = lo; md = ld; c1 = vec3(0.0, yI, 0.0); r1 = vec3(0.1, 0.14, 0.1) * near; c2 = vec3(0.0, 0.5 * (yI + Hw), 0.0); r2e = vec3(0.005, 0.5 * (Hw - yI), 0.005); }
    if (isO > 0.5) { mo = lo; md = ld; c1 = vec3(0.0, yI + 0.03 * sin(bb * PI * 0.5), 0.0); r1 = vec3(0.075 * smoothstep(-0.05, 1.0, dist) * appear + 1e-3); r2e = vec3(1e-4); }
    vec3 nn, n2;
    float t1 = ellip(mo, md, c1, r1, nn), t2 = ellip(mo, md, c2, r2e, n2);
    if (t1 < tS) {
      vec3 hq = mo + md * t1 - c1;
      float fres = pow(1.0 - abs(dot(nn, md)), 2.0);
      float rib = isL * smoothstep(0.3, 0.5, abs(fract((hq.y) * 28.0) - 0.5));
      // The orb: a hot core, a bright rim, and meridians turning round it.
      float sa = bb * PI * 0.5, mer = smoothstep(0.6, 0.9, abs(sin((nn.x * cos(sa) + nn.z * sin(sa)) * 5.0)));
      vec3 orb = iC * (0.45 + 1.1 * fres + 1.6 * pow(max(dot(nn, -md), 0.0), 6.0)) * (1.0 - 0.35 * mer);
      // The cap: deep colour, darker toward the crown, fine veins running out from it, luminous
      // spots, a translucent rim where it thins; underneath, gills radiating and glowing.
      float rr = length(hq.xz) / sz, an = atan(hq.z, hq.x);
      float veins = 0.8 + 0.2 * sin(an * 22.0 + 3.0 * sin(rr * 6.0 + fk));
      float spots = smoothstep(0.62, 0.7, vnoise(hq.xz * 9.0 / sz + fk * 5.0 + 3.0)) * step(0.0, nn.y) * (isH + isP + isT);
      vec3 cap = capC * (0.35 + 0.9 * rr * rr) * veins * (0.7 + 0.3 * nn.y);
      cap += mix(iC, capC * 2.0, 0.4) * (0.55 * pow(fres, 2.5) + 0.2 * smoothstep(0.75, 1.0, rr)) * mpulse;
      cap = mix(cap, mix(vec3(1.0, 0.97, 0.9), iC, 0.3) * (0.8 + 0.3 * A) * mpulse, spots * 0.85);
      float under = smoothstep(-0.05, -0.3, nn.y);
      float gill = 0.35 + 0.65 * pow(0.5 + 0.5 * sin(an * 40.0), 2.0);
      cap = mix(cap, iC * (0.25 + 1.0 * gill) * (0.5 + 0.6 * rr) * mpulse, under);
      col = mix(mix(iC * 1.2, vec3(1.3), 0.3) * (1.0 - 0.5 * rib), orb, isO);
      col = mix(col, cap * (0.9 + 0.4 * trip), isM);
      tS = t1; mushHit = isM;
    }
    if (t2 < tS) {
      vec3 sq = mo + md * t2 - c2;
      vec3 stem = mix(vec3(0.75, 0.72, 0.6) * 0.2, iC * 0.6, smoothstep(-0.3, 0.9, sq.y / r2e.y)) * (0.6 + 0.4 * n2.x * n2.x) * mpulse;
      col = mix(stem, vec3(0.03), isL); tS = t2; mushHit = isM;
    }
    // Spores rising off each cap, glittering on the hats.
    float spf = fract(bb * 0.3 + hk * 3.0);
    vec3 spo = base + vec3(-lean * hst + 0.07 * sin(bb * 0.9 + fk * 2.0), hst + 0.08 + 0.7 * spf, 0.07 * cos(bb * 0.7 + fk));
    float stc = clamp(dot(spo - wo, wd), 0.0, tS);
    vec3 sdv = wo + wd * stc - spo;
    float sr = max(0.008, stc * px * 1.4);
    sr *= sr;
    float svv = sr / (dot(sdv, sdv) + sr);
    glow += mix(iC, vec3(1.0), 0.4) * isM * appear * svv * svv * (1.0 - spf) * (1.5 + 3.0 * B * step(0.5, fract(hk * 7.0 + floor(bb * 2.0) * 0.37)));
  }
  // Flat things across the corridor: a door of light, a portcullis, a curtain of threads.
  float tpl = -lo.z / (abs(ld.z) < 1e-4 ? 1e-4 : ld.z);
  vec2 qp = (lo + ld * tpl).xy;
  float aap = tpl * px;
  float isD = step(abs(kind - 3.0), 0.5), isG = step(abs(kind - 4.0), 0.5), isV = step(abs(kind - 5.0), 0.5);
  // The door: an arch with a luminous veil.
  float dw = gA * 0.9, dh = min(0.9 * Hw, 1.3);
  float dd = max(qp.y < dh - dw ? abs(qp.x) - dw : length(vec2(qp.x, qp.y - dh + dw)) - dw, -qp.y);
  float frame = smoothstep(0.03 + aap, 0.018, abs(dd + 0.02));
  float veil = smoothstep(aap, -aap, dd) * (0.35 + 0.25 * sin(qp.x * 40.0 + bb * 2.0) * sin(qp.y * 7.0 - bb * 3.0));
  // The portcullis: down until the last bar before you reach it, then a notch up on every kick
  // (all at once on the drop), so it is always clear by the time you get there.
  float gx = clamp(4.3 - dist / max(pace, 0.01), 0.0, 4.0);
  float lift = max((floor(gx) + smoothstep(0.0, 0.3, fract(gx))) / 4.0, step(6.5, u_scene) * smoothstep(0.0, 1.0, u_since));
  vec2 gq = qp - vec2(0.0, lift * Hw * 0.95);
  float gbx = abs(fract(gq.x * 8.0 + 0.5) - 0.5) / 8.0;
  float gate = max(smoothstep(0.02 + aap, 0.013, gbx + max(-gq.y, 0.0) * 0.3) * step(-0.08, gq.y),
                   smoothstep(0.018 + aap, 0.011, abs(fract(gq.y * 3.5) - 0.5) / 3.5) * step(0.0, gq.y)) * step(gq.y, Hw);
  // The curtain: strands swept to the walls as you come up to it, swaying on the hats.
  float part = 1.0 - smoothstep(0.3, 2.2, dist);
  float xs = (qp.x - 0.025 * sin(qp.y * 6.0 + bb * 1.5) * (1.0 + 2.0 * B) * (Hw - qp.y))
           / (1.0 + 2.2 * part * (0.3 + 0.7 * smoothstep(Hw, 0.2, qp.y)));
  float ki = floor(xs / 0.075 + 0.5), vdx = abs(xs - ki * 0.075), hk = h12(vec2(ki, n1)), bot = 0.05 + 0.35 * hk;
  float strand = max(smoothstep(0.005 + aap, 0.002, vdx), smoothstep(0.016 + aap, 0.01, length(vec2(vdx, fract(qp.y * 4.0 + hk) / 4.0 - 0.1))))
               * step(bot, qp.y) * step(abs(ki * 0.075), gA + 0.05) * step(0.05, near);
  vec3 vc = isH > 0.5 ? vec3(0.12, 0.35, 0.08) : (isT > 0.5 ? tripC : thr * 0.9);
  float onP = step(0.0, tpl) * step(tpl, tS) * appear;
  float dnear = smoothstep(0.35, 1.3, dist) * appear;
  col += iC * (0.2 + veil) * isD * onP * smoothstep(aap, -aap, dd) * dnear * smoothstep(0.7, 1.8, dist) * 0.7;
  col += iC * 0.5 * isD * onP * dnear * exp(-abs(dd + 0.02) * 30.0);
  col = mix(col, iC * 1.6, isD * onP * frame * dnear);
  float solid = onP * max(isG * step(0.5, gate), isV * step(0.5, strand));
  col = mix(col, isG * (vec3(0.05, 0.045, 0.04) + hope * 0.35 * (1.0 - smoothstep(0.0, 0.015, gbx))) + isV * vc * (0.4 + 0.6 * smoothstep(bot, Hw, qp.y)), solid);
  tS = mix(tS, tpl, max(solid, isD * onP * frame * dnear));
  // The fallen pillar, lodged across the corridor high up, tilted a little: you walk under it.
  float yc = max(EYE + 0.42, 0.7 * Hw);
  vec2 oo = vec2(0.993 * (lo.y - yc) - 0.12 * lo.x, lo.z), dq = vec2(0.993 * ld.y - 0.12 * ld.x, ld.z);
  float qa = dot(dq, dq), qb = dot(oo, dq), qh = qb * qb - qa * (dot(oo, oo) - 0.027 * appear);
  float tp = (-qb - sqrt(max(qh, 0.0))) / qa;
  vec2 pp = (oo + dq * tp) / 0.165;
  float plit = 0.2 + 0.8 * max(0.0, 0.5 * pp.x - 0.5 * pp.y);
  float flute = 0.75 + 0.25 * smoothstep(0.15, 0.45, abs(fract(pp.y * 2.5 + pp.x * 1.3) - 0.5));
  float pil = step(5.5, kind) * step(0.0, qh) * step(0.0, tp) * step(tp, tS);
  col = mix(col, mix(vec3(0.45, 0.42, 0.38), vec3(0.02), isN) * (amb * 3.0 + hope * 0.8 * plit) * flute + isN * thr * smoothstep(0.85, 0.99, abs(pp.y)) * 1.5, pil);
  tS = mix(tS, tp, pil);
  // Walking through a door or reaching the orb is a flash of light; eating the mushrooms, a bloom.
  glow += (hope * 0.6 * (isD + isO) + iC * 0.12 * isM) * exp(-abs(dist) * 14.0) * step(-0.5, kind) * max(0.0, 1.0 - 1.6 * dot(sp, sp));
  float itemHit = step(tS, t - 1e-4);
  t = min(t, tS);

  // ---- The air -----------------------------------------------------------------------------
  float fogD = (0.03 + 0.09 * p_fog) * 16.0 / FAR;
  float fogA = max(1.0 - exp(-t * t * fogD * fogD), smoothstep(0.6 * FAR, FAR, t)) * (1.0 - 0.7 * isC * sky);
  float mtc = clamp(dot(vec3(0.0, 0.15, 0.0) - lo, ld), 0.0, t);
  float rayDark = isM * appear * max(smoothstep(1.6, 0.35, length(lo + ld * mtc - vec3(0.0, 0.15, 0.0))), mushHit);
  fogA *= 1.0 - 0.8 * rayDark;
  vec3 air = (Lc[0] * airGlow(ro, rd, Lp[0], t, 0.12) + Lc[1] * airGlow(ro, rd, Lp[1], t, 0.12) + 0.4 * Lc[2] * airGlow(ro, rd, Lp[2], t, 0.12)) * 0.022;
  air *= 1.0 - 0.7 * rayDark;
  col = mix(col, fogC, fogA);
  // Eating the mushrooms: a bloom, then a ring of colour racing away down the corridor.
  float shock = exp(-(t - 1.0 - 6.0 * eat) * (t - 1.0 - 6.0 * eat) * 2.5) * (1.0 - smoothstep(0.3, 3.0, eat)) * p_trip;
  col += hsv(fract(hue + 0.5 + 0.1 * t), 0.8, 1.0) * shock * 1.2 + tripC * ( (1.0 - smoothstep(0.0, 0.45, eat)) * 0.45 * p_trip * max(0.0, 1.0 - 1.2 * dot(sp, sp)));
  // Rays from the light round the corner: a cone about the way to the lamp, streaked, cut off
  // where a wall stands in front of it.
  vec3 lv = Lp[0] - ro;
  float ll = length(lv);
  lv /= ll;
  float ca0 = max(dot(rd, lv), 0.0);
  vec3 b1 = normalize(cross(lv, vec3(0.0, 1.0, 0.0)) + 1e-4);
  float ang = atan(dot(rd, b1), dot(rd, cross(b1, lv)));
  float rays = 0.55 + 0.45 * sin(ang * 9.0 + 0.7 * sin(ang * 4.0 + bb * 0.25)) * sin(ang * 5.0 - bb * 0.15);
  air += Lc[0] * pow(ca0, 6.0) * rays * smoothstep(0.55, 0.95, t / ll) * 0.09 * (1.0 - isP);
  col += (air + (skyC * 0.4 + hope * 0.6) * (1.0 - exp(-shaft * 1.5)) * (0.08 + 0.9 * rev)) * (1.0 - 0.65 * isP) + glow * (1.0 - isP);

  // The paper world: every line is ink, shade is hatching drawn by how much light falls there
  // (not darkness), the light is a warm wash, the thread red ink, the fireflies ink dots.
  float lumL = isW + isF + isC > 0.5 ? dot(L, vec3(0.3, 0.5, 0.2)) * aoF : 1.0;
  vec2 s2 = uv * vec2(u_aspect, 1.0) / max(u_px, 1e-4);
  float hatch = max(step(lumL, 0.3) * smoothstep(0.3, 0.45, abs(fract((s2.x + s2.y) / 6.0) - 0.5)),
                    step(lumL, 0.2) * smoothstep(0.3, 0.45, abs(fract((s2.x - s2.y) / 6.0) - 0.5))) * (1.0 - fogA);
  ink = max(max(ink * (1.0 - fogA * 0.8), hatch * 0.75) * (1.0 - core), smoothstep(0.15, 0.5, dot(mglow, vec3(0.5))));
  vec3 paper = vec3(0.95, 0.92, 0.84) * (0.9 + 0.1 * clamp(lumL, 0.0, 1.0)) + hope * (0.35 * clamp(lumL - 0.6, 0.0, 1.0) + 0.25 * fogA) + glow * 0.3;
  paper = mix(mix(paper, vec3(0.06, 0.05, 0.05), ink), thr, core * (1.0 - fogA));
  paper = mix(paper, mix(vec3(0.95, 0.92, 0.84), col, 0.75), itemHit);
  col = mix(col + mglow, paper, isP);
  // A soft lift for the projector, which crushes dark mids: darks and mids up about 2.5x, highlights eased, black stays black.
  col = 1.0 - exp(-col * 4.2 * p_bright);
  col = pow(col, vec3(0.85));
  vec2 vq = uv - 0.5;
  return col * (1.0 - p_vign * dot(vq, vq) * 2.2);
}
