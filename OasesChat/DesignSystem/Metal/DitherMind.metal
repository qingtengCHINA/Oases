#include <metal_stdlib>
using namespace metal;

// The thinking "mind": a small hand-modelled 3D object (a magnifier while searching, a laptop
// while running commands, a pencil while writing…), ray-marched at a few dozen pixels, lit,
// and ordered-dithered to one bit, with a dotted shadow on the floor. Every object is built
// here from plain distance-field primitives. Mirrors `DitherMindUniforms` in
// DitherMindRenderer.swift (float4, then float2, then floats; 64 bytes).
struct DitherMindUniforms {
    float4 ink;
    float2 res;        // drawable size in mind pixels
    float  time;       // object animation clock (stops when the mind settles)
    float  form;       // 0 scattered ... 1 formed
    float  morph;      // 0 shape A ... 1 shape B
    float  shapeA;
    float  shapeB;
    float  energy;     // sparkle
    float  shimmer;    // Bayer offset, steps
    float  yaw;
    float  pitch;
    float  lightInk;   // 1 when the ink is lighter than the page (dark mode)
};

struct MindOut { float4 position [[position]]; };

vertex MindOut ditherMindVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    MindOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

constant float kGround = -0.66;

// MARK: - Primitives

static inline float mindHash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static inline float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

static inline float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static inline float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

static inline float sdRoundBox(float3 p, float3 b, float r) {
    return sdBox(p, b - r) - r;
}

static inline float sdBox2(float2 p, float2 b) {
    float2 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

static inline float sdRoundRect2(float2 p, float2 b, float r) {
    return sdBox2(p, b - r) - r;
}

/// A 2D distance extruded to half-depth `h` with rounded edges of radius `r`.
static inline float extrude(float d2, float z, float h, float r) {
    float2 w = float2(d2 + r, abs(z) - h + r);
    return min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - r;
}

static inline float sdSphere(float3 p, float r) { return length(p) - r; }

static inline float sdEllipsoid(float3 p, float3 r) {
    return (length(p / r) - 1.0) * min(r.x, min(r.y, r.z));
}

/// Cylinder along y.
static inline float sdCylY(float3 p, float r, float h) {
    float2 d = abs(float2(length(p.xz), p.y)) - float2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

/// Cylinder along z (a disc facing the camera).
static inline float sdCylZ(float3 p, float r, float h) {
    return sdCylY(float3(p.x, p.z, p.y), r, h);
}

/// Ring lying in the xz plane.
static inline float sdTorusY(float3 p, float R, float r) {
    return length(float2(length(p.xz) - R, p.y)) - r;
}

/// Ring standing in the xy plane (facing the camera).
static inline float sdTorusZ(float3 p, float R, float r) {
    return length(float2(length(p.xy) - R, p.z)) - r;
}

static inline float sdCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

/// Cone along y from radius r1 at -h to r2 at +h.
static inline float sdCappedCone(float3 p, float h, float r1, float r2) {
    float2 q = float2(length(p.xz), p.y);
    float2 k1 = float2(r2, h);
    float2 k2 = float2(r2 - r1, 2.0 * h);
    float2 ca = float2(q.x - min(q.x, (q.y < 0.0) ? r1 : r2), abs(q.y) - h);
    float2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0, 1.0);
    float s = (cb.x < 0.0 && ca.y < 0.0) ? -1.0 : 1.0;
    return s * sqrt(min(dot(ca, ca), dot(cb, cb)));
}

/// Hexagonal prism along z; `h.x` is the apothem, `h.y` the half length.
static inline float sdHexPrism(float3 p, float2 h) {
    const float3 k = float3(-0.8660254, 0.5, 0.57735);
    p = abs(p);
    p.xy -= 2.0 * min(dot(k.xy, p.xy), 0.0) * k.xy;
    float2 d = float2(length(p.xy - float2(clamp(p.x, -k.z * h.x, k.z * h.x), h.x)) * sign(p.y - h.x), p.z - h.y);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

// MARK: - Objects

// 0 · Orb with a ring and a small moon: plain thinking.
static float objOrb(float3 p, float t) {
    float3 c = p - float3(0.0, 0.02, 0.0);
    float body = sdSphere(c, 0.36);
    float3 q = c;
    q.yz = rot(0.42) * q.yz;
    q.xy = rot(-0.28) * q.xy;
    float ring = sdTorusY(q, 0.58, 0.032);
    float moon = sdSphere(q - float3(0.58 * cos(t * 0.8), 0.0, 0.58 * sin(t * 0.8)), 0.075);
    return min(body, min(ring, moon));
}

// 1 · Magnifying glass: searching.
static float objMagnifier(float3 p) {
    float3 c = float3(-0.13, 0.15, 0.0);
    float3 q = p - c;
    float rim = sdTorusZ(q, 0.33, 0.062);
    float lens = sdCylZ(q, 0.31, 0.016);
    float2 dir = normalize(float2(1.0, -1.0));
    float neck = sdCapsule(p, c + float3(dir * 0.37, 0.0), c + float3(dir * 0.52, 0.0), 0.048);
    float grip = sdCapsule(p, c + float3(dir * 0.55, 0.0), c + float3(dir * 0.93, 0.0), 0.085);
    return min(min(rim, lens), min(neck, grip));
}

// 2 · Desk globe: the web.
static float objGlobe(float3 p, float t) {
    float3 c = float3(0.0, 0.1, 0.0);
    float3 q = p - c;
    q.xy = rot(0.4) * q.xy;
    float3 s = q;
    s.xz = rot(t * 0.35) * s.xz;
    const float R = 0.43;
    float ball = sdSphere(s, R);
    float shell = abs(length(s) - R) - 0.03;
    float lat = min(abs(s.y), abs(abs(s.y) - 0.21)) - 0.012;
    float merid = abs(sin(atan2(s.z, s.x) * 3.0)) * length(s.xz) - 0.012;
    ball = max(ball, -max(min(lat, merid), shell));
    float arc = max(sdTorusZ(q, 0.52, 0.022), -q.x);
    float stem = sdCapsule(p, float3(-0.2, -0.39, 0.0), float3(-0.12, -0.6, 0.0), 0.032);
    float base = sdCylY(p - float3(-0.12, -0.63, 0.0), 0.24, 0.03) - 0.008;
    return min(ball, min(arc, min(stem, base)));
}

// 3 · A page with a folded corner and lines of text: reading a file.
static float objDocument(float3 p) {
    float3 q = p - float3(0.04, 0.02, 0.0);
    q.yz = rot(-0.12) * q.yz;
    float back = sdRoundBox(q - float3(-0.08, -0.07, -0.07), float3(0.37, 0.5, 0.02), 0.012);
    float page = sdRoundBox(q, float3(0.37, 0.5, 0.024), 0.012);
    const float2 n = float2(0.7071068, 0.7071068);
    float2 cp = q.xy - float2(0.37, 0.5);
    float cutLine = dot(cp, n) + 0.14;
    page = max(page, cutLine);
    float2 r = cp - 2.0 * cutLine * n;
    float flap = max(max(max(r.x, r.y), cutLine), abs(q.z - 0.036) - 0.008);
    float lines = sdBox(q - float3(-0.1, 0.32, 0.03), float3(0.2, 0.034, 0.022));
    for (int i = 0; i < 4; i++) {
        float y = 0.15 - float(i) * 0.13;
        float w = i == 3 ? 0.16 : 0.26;
        lines = min(lines, sdBox(q - float3(-0.27 + w, y, 0.03), float3(w, 0.024, 0.022)));
    }
    page = max(page, -lines);
    return min(page, min(back, flap));
}

// 4 · An open book lying on the desk: studying, explaining.
static float objBook(float3 p) {
    float3 q = p - float3(0.0, -0.3, 0.05);
    q.yz = rot(1.05) * q.yz;
    float3 m = float3(abs(q.x), q.y, q.z);
    m.xz = rot(-0.16) * m.xz;
    float bulge = 0.07 * sin(clamp(m.x / 0.64, 0.0, 1.0) * 3.14159);
    float3 pg = m - float3(0.33, 0.0, bulge);
    float page = sdRoundBox(pg, float3(0.31, 0.42, 0.02), 0.012);
    float lines = 1e9;
    for (int i = 0; i < 6; i++) {
        float y = 0.3 - float(i) * 0.12;
        lines = min(lines, sdBox(pg - float3(0.0, y, 0.026), float3(0.22, 0.02, 0.014)));
    }
    page = max(page, -lines);
    float cover = sdRoundBox(m - float3(0.345, 0.0, -0.04), float3(0.345, 0.45, 0.016), 0.012);
    float spine = sdCylY(q - float3(0.0, 0.0, -0.045), 0.035, 0.45);
    return min(min(page, cover), spine);
}

// 5 · A laptop with a prompt on the screen: running commands.
static float objLaptop(float3 p) {
    float3 q = p - float3(0.0, -0.02, 0.0);
    float base = sdRoundBox(q - float3(0.0, -0.4, 0.12), float3(0.56, 0.028, 0.34), 0.02);
    float3 k = q - float3(0.0, -0.37, 0.06);
    const float2 cell = float2(0.088, 0.088);
    float2 id = clamp(round(k.xz / cell), float2(-5.0, -2.0), float2(5.0, 2.0));
    float2 r = k.xz - id * cell;
    float keys = sdRoundBox(float3(r.x, k.y, r.y), float3(0.034, 0.012, 0.034), 0.006);
    float3 s = q - float3(0.0, -0.37, -0.22);
    s.yz = rot(0.24) * s.yz;
    float screen = sdRoundBox(s - float3(0.0, 0.37, 0.0), float3(0.56, 0.37, 0.024), 0.02);
    screen = max(screen, -sdBox(s - float3(0.0, 0.38, 0.032), float3(0.5, 0.31, 0.014)));
    float3 g = s - float3(-0.24, 0.42, 0.018);
    float chevron = min(sdCapsule(g, float3(-0.08, 0.09, 0.0), float3(0.04, 0.0, 0.0), 0.03),
                        sdCapsule(g, float3(0.04, 0.0, 0.0), float3(-0.08, -0.09, 0.0), 0.03));
    float cursor = sdCapsule(g, float3(0.12, -0.1, 0.0), float3(0.28, -0.1, 0.0), 0.03);
    return min(min(base, keys), min(screen, min(chevron, cursor)));
}

// 6 · Angle brackets and a slash: code.
static float objCode(float3 p) {
    float3 m = float3(abs(p.x), p.y, p.z);
    const float r = 0.062;
    float brackets = min(sdCapsule(m, float3(0.34, 0.27, 0.0), float3(0.62, 0.0, 0.0), r),
                         sdCapsule(m, float3(0.62, 0.0, 0.0), float3(0.34, -0.27, 0.0), r));
    float slash = sdCapsule(p, float3(0.12, 0.38, 0.0), float3(-0.12, -0.38, 0.0), r);
    return min(brackets, slash);
}

// 7 · A pencil: writing, editing.
static float objPencil(float3 p) {
    float3 q = p - float3(0.04, 0.02, 0.0);
    q.xy = rot(-2.4) * q.xy;
    float body = sdHexPrism(float3(q.x, q.z, q.y), float2(0.1, 0.36)) - 0.004;
    float wood = sdCappedCone(q - float3(0.0, 0.5, 0.0), 0.14, 0.1, 0.03);
    float lead = sdCappedCone(q - float3(0.0, 0.67, 0.0), 0.035, 0.03, 0.004);
    float ferrule = sdCylY(q - float3(0.0, -0.41, 0.0), 0.106, 0.055);
    float bands = abs(abs(q.y + 0.41) - 0.025) - 0.007;
    ferrule = max(ferrule, -max(bands, 0.097 - length(q.xz)));
    float eraser = sdCylY(q - float3(0.0, -0.54, 0.0), 0.088, 0.075) - 0.012;
    return min(min(body, wood), min(lead, min(ferrule, eraser)));
}

// 8 · A camera: images and photos.
static float objCamera(float3 p) {
    float3 q = p - float3(0.0, -0.06, 0.0);
    float body = sdRoundBox(q, float3(0.56, 0.33, 0.19), 0.08);
    float hump = sdRoundBox(q - float3(-0.2, 0.36, 0.0), float3(0.17, 0.08, 0.15), 0.04);
    float shutter = sdCylY(q - float3(0.34, 0.37, 0.0), 0.07, 0.035) - 0.01;
    float flash = sdRoundBox(q - float3(0.36, 0.19, 0.19), float3(0.08, 0.045, 0.02), 0.012);
    float3 l = q - float3(0.03, -0.02, 0.19);
    float barrel = sdCylZ(l - float3(0.0, 0.0, 0.07), 0.24, 0.08) - 0.015;
    barrel = max(barrel, -max(abs(length(l.xy) - 0.2) - 0.012, -(l.z - 0.13)));
    barrel = max(barrel, -sdCylZ(l - float3(0.0, 0.0, 0.17), 0.15, 0.04));
    float glass = sdSphere(l - float3(0.0, 0.0, 0.02), 0.15);
    return min(min(body, hump), min(min(shutter, flash), min(barrel, glass)));
}

// 9 · A light bulb: ideas.
static float objBulb(float3 p) {
    float3 q = p - float3(0.0, 0.06, 0.0);
    float bulb = sdSphere(q - float3(0.0, 0.14, 0.0), 0.35);
    float neck = sdCappedCone(q - float3(0.0, -0.2, 0.0), 0.14, 0.15, 0.27);
    float glass = smin(bulb, neck, 0.12);
    float screw = sdCylY(q - float3(0.0, -0.44, 0.0), 0.155, 0.11);
    screw -= 0.014 * (0.5 + 0.5 * sin((q.y + 0.44) * 62.0));
    float contact = sdCappedCone(q - float3(0.0, -0.6, 0.0), 0.05, 0.05, 0.12);
    return min(glass, min(screw, contact));
}

// 10 · An alarm clock: time, schedules, reminders.
static float objClock(float3 p, float t) {
    float3 q = p - float3(0.0, -0.03, 0.0);
    float body = sdCylZ(q, 0.42, 0.13) - 0.03;
    body = max(body, -sdCylZ(q - float3(0.0, 0.0, 0.16), 0.34, 0.03));
    float a = atan2(q.y, q.x);
    const float sector = 6.2831853 / 12.0;
    float ai = round(a / sector) * sector;
    float2 tp = rot(-ai) * q.xy;
    float ticks = sdBox(float3(tp.x - 0.28, tp.y, q.z - 0.13), float3(0.035, 0.012, 0.02));
    float2 hh = rot(t * 0.08 + 2.3) * float2(0.0, 0.15);
    float2 mh = rot(-t * 0.9 - 0.6) * float2(0.0, 0.23);
    float hands = min(sdCapsule(q, float3(0.0, 0.0, 0.14), float3(hh, 0.14), 0.026),
                      sdCapsule(q, float3(0.0, 0.0, 0.15), float3(mh, 0.15), 0.02));
    float hub = sdCylZ(q - float3(0.0, 0.0, 0.15), 0.04, 0.02);
    float3 m = float3(abs(q.x), q.y, q.z);
    float bell = max(sdSphere(m - float3(0.29, 0.42, -0.02), 0.15), 0.38 - m.y);
    float legs = sdCapsule(m, float3(0.24, -0.38, 0.0), float3(0.34, -0.56, 0.0), 0.04);
    float knob = sdCapsule(q, float3(0.0, 0.44, -0.02), float3(0.0, 0.53, -0.02), 0.035);
    return min(min(body, min(ticks, hands)), min(min(hub, bell), min(legs, knob)));
}

// 11 · A standing coin beside a short stack: prices, money.
static float objCoins(float3 p) {
    float d = 1e9;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float3 c = float3(-0.38 + sin(fi * 1.7) * 0.03, kGround + 0.045 + fi * 0.088, -0.05 + cos(fi * 2.3) * 0.025);
        float3 q = p - c;
        float coin = sdCylY(q, 0.25, 0.036) - 0.008;
        coin -= 0.006 * step(0.24, length(q.xz)) * (0.5 + 0.5 * sin(atan2(q.z, q.x) * 40.0));
        d = min(d, coin);
    }
    float3 s = p - float3(0.14, kGround + 0.4, 0.1);
    s.xz = rot(0.3) * s.xz;
    float face = sdCylZ(s, 0.38, 0.045) - 0.01;
    face = max(face, -max(abs(length(s.xy) - 0.29) - 0.018, -(s.z - 0.03)));
    float mark = extrude(sdBox2(rot(0.785398) * s.xy, float2(0.1, 0.1)), s.z - 0.055, 0.014, 0.008);
    return min(d, min(face, mark));
}

// 12 · An open box of index cards: memory.
static float objCardBox(float3 p) {
    float3 q = p - float3(0.0, kGround + 0.2, 0.0);
    float box = sdRoundBox(q, float3(0.46, 0.2, 0.34), 0.03);
    box = max(box, -sdBox(q - float3(0.0, 0.08, 0.0), float3(0.42, 0.2, 0.3)));
    box = max(box, -sdBox(q - float3(0.0, -0.02, 0.35), float3(0.1, 0.035, 0.02)));
    float cards = 1e9;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float3 c = q - float3(0.0, 0.28 + 0.02 * sin(fi * 2.3), -0.24 + fi * 0.095);
        c.yz = rot(-0.12) * c.yz;
        float card = sdRoundBox(c, float3(0.38, 0.25, 0.008), 0.02);
        float tab = sdRoundBox(c - float3(-0.28 + fmod(fi * 0.23, 0.56), 0.27, 0.0), float3(0.07, 0.04, 0.008), 0.015);
        cards = min(cards, min(card, tab));
    }
    return min(box, cards);
}

// 13 · Two beamed notes: music.
static float objNotes(float3 p) {
    float3 h1 = p - float3(-0.27, -0.42, 0.0);
    h1.xy = rot(0.45) * h1.xy;
    float3 h2 = p - float3(0.29, -0.3, 0.0);
    h2.xy = rot(0.45) * h2.xy;
    float heads = min(sdEllipsoid(h1, float3(0.15, 0.105, 0.1)), sdEllipsoid(h2, float3(0.15, 0.105, 0.1)));
    float stems = min(sdCapsule(p, float3(-0.14, -0.38, 0.0), float3(-0.14, 0.36, 0.0), 0.03),
                      sdCapsule(p, float3(0.42, -0.26, 0.0), float3(0.42, 0.48, 0.0), 0.03));
    float3 b = p - float3(0.14, 0.42, 0.0);
    b.xy = rot(-0.21) * b.xy;
    float beams = min(sdRoundBox(b, float3(0.3, 0.05, 0.045), 0.015),
                      sdRoundBox(b - float3(0.0, -0.14, 0.0), float3(0.3, 0.04, 0.045), 0.015));
    return min(heads, min(stems, beams));
}

// 14 · A heart.
static float objHeart(float3 p) {
    float3 q = p - float3(0.0, 0.04, 0.0);
    float2 h = float2(abs(q.x), q.y);
    float lobe = length(h - float2(0.19, 0.13)) - 0.25;
    float tipBox = sdBox2(rot(0.785398) * (h - float2(0.0, -0.1)), float2(0.28, 0.28));
    float d2 = smin(lobe, tipBox, 0.05);
    return extrude(d2, q.z, 0.13, 0.1);
}

// One gear facing the camera.
static float gear(float3 q, float R, float teeth, float spin, float th) {
    float sector = 6.2831853 / teeth;
    float a = atan2(q.y, q.x) - spin;
    float ai = round(a / sector) * sector + spin;
    float2 tp = rot(-ai) * q.xy;
    float tooth = sdRoundBox(float3(tp.x - R, tp.y, q.z), float3(0.065, 0.042, th), 0.012);
    float disc = sdCylZ(q, R, th) - 0.006;
    float g = min(disc, tooth);
    float hole = sdCylZ(q, R * 0.28, th + 0.1);
    const float s4 = 6.2831853 / 4.0;
    float a4 = atan2(q.y, q.x) - spin - 0.785398;
    float2 wp = rot(-(round(a4 / s4) * s4 + 0.785398 + spin)) * q.xy;
    float window = sdCylZ(float3(wp.x - R * 0.6, wp.y, q.z), R * 0.17, th + 0.1);
    return max(g, -min(hole, window));
}

// 15 · Two meshing gears: working, building, settings.
static float objGears(float3 p, float t) {
    float big = gear(p - float3(-0.17, 0.12, 0.0), 0.33, 10.0, t * 0.6, 0.075);
    float minor = gear(p - float3(0.36, -0.27, 0.04), 0.21, 7.0, -t * 0.6 * 10.0 / 7.0 + 0.22, 0.075);
    return min(big, minor);
}

// 16 · A speech bubble with typing dots: writing the reply.
static float objBubble(float3 p, float t) {
    float3 q = p - float3(0.0, 0.08, 0.0);
    float box = sdRoundRect2(q.xy, float2(0.6, 0.37), 0.24);
    float2 tq = rot(0.55) * (q.xy - float2(-0.36, -0.4));
    float tail = sdRoundRect2(tq, float2(0.07, 0.15), 0.04);
    float bubble = extrude(smin(box, tail, 0.07), q.z, 0.1, 0.05);
    float dots = 1e9;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float lift = 0.035 * max(0.0, sin(t * 5.0 - fi * 0.9));
        dots = min(dots, sdSphere(q - float3(-0.24 + fi * 0.24, lift, 0.1), 0.07));
    }
    return min(bubble, dots);
}

// 17 · A desk calendar: dates, plans.
static float objCalendar(float3 p) {
    float3 q = p - float3(0.0, -0.04, 0.0);
    float page = sdRoundBox(q, float3(0.5, 0.47, 0.08), 0.05);
    page = max(page, -sdBox(q - float3(0.0, 0.24, 0.08), float3(0.5, 0.012, 0.02)));
    const float2 cell = float2(0.2, 0.15);
    float2 k = q.xy - float2(0.0, -0.1);
    float2 id = float2(clamp(floor(k.x / cell.x) + 0.5, -1.5, 1.5), clamp(round(k.y / cell.y), -1.0, 1.0));
    float2 r = k - id * cell;
    float square = sdBox(float3(r.x, r.y, q.z - 0.08), float3(0.07, 0.05, 0.02));
    page = max(page, -square);
    float marker = sdRoundBox(q - float3(0.3, -0.1, 0.075), float3(0.066, 0.046, 0.014), 0.012);
    float3 m = float3(abs(q.x), q.y, q.z);
    float3 rq = m - float3(0.25, 0.46, 0.0);
    float rings = length(float2(length(rq.yz) - 0.075, rq.x)) - 0.026;
    return min(min(page, marker), rings);
}

// 18 · A map pin on a ring: places, location.
static float objPin(float3 p) {
    float3 q = p - float3(0.0, 0.06, 0.0);
    float head = sdSphere(q - float3(0.0, 0.2, 0.0), 0.31);
    float tip = sdCappedCone(q - float3(0.0, -0.22, 0.0), 0.28, 0.015, 0.26);
    float pin = smin(head, tip, 0.08);
    pin = max(pin, -sdCylZ(q - float3(0.0, 0.2, 0.0), 0.12, 0.5));
    float ring = sdTorusY(p - float3(0.0, kGround + 0.02, 0.0), 0.22, 0.02);
    return min(pin, ring);
}

// 19 · A folder with a sheet in it: files, the workspace.
static float objFolder(float3 p) {
    float3 q = p - float3(0.0, -0.06, 0.0);
    float back = sdRoundBox(q - float3(0.0, 0.0, -0.05), float3(0.58, 0.42, 0.02), 0.05);
    float tab = sdRoundBox(q - float3(-0.3, 0.44, -0.05), float3(0.24, 0.08, 0.02), 0.04);
    float3 pq = q - float3(0.04, 0.12, -0.015);
    pq.xy = rot(-0.05) * pq.xy;
    float paper = sdRoundBox(pq, float3(0.48, 0.36, 0.008), 0.006);
    paper = max(paper, -sdBox(pq - float3(-0.08, 0.24, 0.01), float3(0.3, 0.02, 0.012)));
    float3 f = q - float3(0.0, -0.42, 0.02);
    f.yz = rot(-0.14) * f.yz;
    float front = sdRoundBox(f - float3(0.0, 0.29, 0.0), float3(0.58, 0.29, 0.02), 0.05);
    return min(min(back, tab), min(paper, front));
}

static float shapeSDF(int id, float3 p, float t) {
    switch (id) {
        case 1: return objMagnifier(p);
        case 2: return objGlobe(p, t);
        case 3: return objDocument(p);
        case 4: return objBook(p);
        case 5: return objLaptop(p);
        case 6: return objCode(p);
        case 7: return objPencil(p);
        case 8: return objCamera(p);
        case 9: return objBulb(p);
        case 10: return objClock(p, t);
        case 11: return objCoins(p);
        case 12: return objCardBox(p);
        case 13: return objNotes(p);
        case 14: return objHeart(p);
        case 15: return objGears(p, t);
        case 16: return objBubble(p, t);
        case 17: return objCalendar(p);
        case 18: return objPin(p);
        case 19: return objFolder(p);
        default: return objOrb(p, t);
    }
}

static inline float mindScene(float3 p, constant DitherMindUniforms& U) {
    float bob = 0.02 * sin(U.time * 1.3);
    float3 q = p - float3(0.0, bob, 0.0);
    float a = shapeSDF(int(U.shapeA), q, U.time);
    if (U.morph <= 0.001) { return a; }
    float b = shapeSDF(int(U.shapeB), q, U.time);
    return mix(a, b, U.morph);
}

static inline float3 mindNormal(float3 p, constant DitherMindUniforms& U) {
    const float2 k = float2(1.0, -1.0);
    const float h = 0.004;
    return normalize(k.xyy * mindScene(p + k.xyy * h, U) +
                     k.yyx * mindScene(p + k.yyx * h, U) +
                     k.yxy * mindScene(p + k.yxy * h, U) +
                     k.xxx * mindScene(p + k.xxx * h, U));
}

/// How much of the light reaches `p` (1 lit … 0 in shadow).
static inline float mindShadow(float3 p, float3 L, constant DitherMindUniforms& U) {
    float lit = 1.0;
    float t = 0.02;
    for (int i = 0; i < 24; i++) {
        float d = mindScene(p + L * t, U);
        lit = min(lit, 10.0 * d / t);
        if (lit < 0.02) { return 0.0; }
        t += clamp(d, 0.02, 0.2);
        if (t > 2.2) { break; }
    }
    return clamp(lit, 0.0, 1.0);
}

fragment float4 ditherMindFragment(MindOut in [[stage_in]],
                                   constant DitherMindUniforms& U [[buffer(0)]])
{
    // Coarse pixels while the shape is still gathering, finer as it forms.
    float block = U.form < 0.3 ? 4.0 : (U.form < 0.6 ? 3.0 : (U.form < 0.85 ? 2.0 : 1.0));
    float2 cell = floor(in.position.xy / block) * block + 0.5 * block;
    float2 uv = (cell - 0.5 * U.res) / (0.5 * U.res.y);
    uv.y = -uv.y;

    // Gathering: each pixel samples from a scattered, turned and enlarged position.
    float kf = (1.0 - U.form) * (1.0 - U.form);
    if (kf > 0.0001) {
        float2 jitter = float2(mindHash(cell + 3.1), mindHash(cell + 7.7)) - 0.5;
        float ang = kf * 1.4 * sin(U.time * 0.7);
        float c = cos(ang), sn = sin(ang);
        uv = float2(c * uv.x - sn * uv.y, sn * uv.x + c * uv.y) * (1.0 + kf * 0.6) + jitter * kf * 0.9;
    }

    // A camera a little above the object, swaying around it.
    const float dist = 2.45;
    float3 ro = float3(dist * cos(U.pitch) * sin(U.yaw), dist * sin(U.pitch), dist * cos(U.pitch) * cos(U.yaw));
    float3 target = float3(0.0, -0.06, 0.0);
    float3 fw = normalize(target - ro);
    float3 right = normalize(cross(fw, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, fw);
    float3 rd = normalize(fw * 2.5 + right * uv.x + up * uv.y);
    const float3 L = normalize(float3(-0.45, 0.72, 0.62));

    float brightness = -1.0;   // < 0: nothing here
    bool hit = false;
    float t = 0.0;
    float b = dot(ro, rd);
    float disc = b * b - (dot(ro, ro) - 1.05 * 1.05);
    if (disc > 0.0) {
        t = max(0.0, -b - sqrt(disc));
        float tEnd = -b + sqrt(disc);
        for (int i = 0; i < 80; i++) {
            float3 p = ro + rd * t;
            float d = mindScene(p, U);
            if (d < 0.0012 * (1.0 + t)) { hit = true; break; }
            t += d * 0.85;
            if (t > tEnd) { break; }
        }
    }
    if (hit) {
        float3 p = ro + rd * t;
        float3 n = mindNormal(p, U);
        float diffuse = max(0.0, dot(n, L));
        float shade = diffuse > 0.0 ? mindShadow(p + n * 0.01, L, U) : 0.0;
        float ao = clamp(0.55 + 0.45 * mindScene(p + n * 0.08, U) / 0.08, 0.0, 1.0);
        // Grooves and engraved lines go dark, so the details read at a few dozen pixels.
        float cavity = clamp(mindScene(p + n * 0.03, U) / 0.03, 0.0, 1.0);
        float rim = pow(1.0 - max(0.0, dot(n, -rd)), 3.0);
        brightness = clamp(0.08 + 0.84 * diffuse * shade * ao + 0.12 * ao + 0.2 * rim, 0.0, 1.0);
        brightness *= 0.35 + 0.65 * cavity;
    }

    float ink = 0.0;
    if (brightness >= 0.0) {
        // Light ink (dark mode) draws the light; dark ink (light mode) draws the shade.
        ink = U.lightInk > 0.5 ? 0.1 + 0.88 * brightness : 0.12 + 0.86 * (1.0 - brightness);
    } else if (rd.y < 0.0) {
        // The floor: only the object's shadow, drawn as sparse dots.
        float tp = (kGround - ro.y) / rd.y;
        float3 g = ro + rd * tp;
        float reach = length(g.xz);
        if (reach < 1.25) {
            float occl = 1.0 - mindShadow(g + float3(0.0, 0.01, 0.0), L, U);
            float2 ic = floor(in.position.xy / max(block, 1.0));
            float dotOn = fmod(ic.x + ic.y, 2.0) < 0.5 && fmod(ic.y, 2.0) < 0.5 ? 1.0 : 0.0;
            ink = occl * dotOn * smoothstep(1.25, 0.6, reach) * 0.95;
        }
    }
    if (brightness < 0.0) {
        // Sparse sparkles around the form, more while it is busy.
        float h = mindHash(cell + floor(U.time * 6.0));
        float r = length(uv);
        float halo = smoothstep(1.4, 0.7, r) * (0.002 + 0.025 * max(0.0, U.energy - 0.9)) * (1.0 + 4.0 * kf);
        if (h < halo) { ink = max(ink, 0.9); }
    }

    // 4×4 ordered dither, 17 levels; the matrix drifts while live (a quiet shimmer).
    const uint bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
    uint2 q = (uint2(int2(floor(in.position.xy))) + uint2(uint(U.shimmer))) & 3u;
    float threshold = float(bayer[q.y * 4u + q.x] + 1u) / 17.0;
    float on = ink < 1.0 / 17.0 ? 0.0 : (ink > 16.0 / 17.0 ? 1.0 : step(threshold, ink));
    return on > 0.5 ? float4(U.ink.rgb * U.ink.a, U.ink.a) : float4(0.0);
}
