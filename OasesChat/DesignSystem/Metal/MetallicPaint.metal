// Metal port of Web/src/components/MetallicPaint.tsx fragment shader.
// 1:1 translation of the GLSL math — variable names kept short to match the
// original so future diffs against the Web shader stay legible.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 vP;
};

struct Uniforms {
    float u_time;
    float u_ratio;
    float u_imgRatio;
    float u_seed;
    float u_scale;
    float u_refract;
    float u_blur;
    float u_liquid;
    float u_bright;
    float u_contrast;
    float u_angle;
    float u_fresnel;
    float u_sharp;
    float u_wave;
    float u_noise;
    float u_chroma;
    float u_distort;
    float u_contour;
    float3 u_lightColor;
    float3 u_darkColor;
    float3 u_tint;
};

vertex VertexOut metallicPaintVertex(uint vid [[vertex_id]]) {
    // Full-screen triangle strip: (-1,-1), (1,-1), (-1,1), (1,1)
    float2 pos = float2((vid & 1) ? 1.0 : -1.0,
                        (vid & 2) ? 1.0 : -1.0);
    VertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.vP = pos * 0.5 + 0.5;
    return out;
}

// pW / aF / lM together build a Perlin-like value-noise field. These match
// the GLSL helpers byte-for-byte; do not "tidy" without comparing output.
static float3 perlinHelper(float3 v, float3 sM) {
    float3 i = floor(v);
    float3 f = fract(v);
    float3 s = sign(fract(v * 0.5) - 0.5);
    float3 h = fract(sM * i + i.yzx);
    float3 c = f * (f - 1.0);
    return s * c * ((h * 16.0 - 4.0) * c - 1.0);
}

static float3 aF(float3 b, float3 c, float3 sM) {
    return perlinHelper(b + c.zxy - perlinHelper(b.zxy + c.yzx, sM) + perlinHelper(b.yzx + c.xyz, sM), sM);
}

static float3 lM(float3 s, float3 p, float3 sM) {
    return (p + aF(s, p, sM)) * 0.5;
}

static float2 fA(float2 vP, float u_ratio, float u_imgRatio) {
    float2 c = vP - 0.5;
    c.x *= u_ratio > u_imgRatio ? u_ratio / u_imgRatio : 1.0;
    c.y *= u_ratio > u_imgRatio ? 1.0 : u_imgRatio / u_ratio;
    return float2(c.x + 0.5, 0.5 - c.y);
}

static float2 rot(float2 p, float r) {
    float c = cos(r);
    float s = sin(r);
    return float2(p.x * c + p.y * s, p.y * c - p.x * s);
}

static float bM(float2 c, float t) {
    float2 l = smoothstep(float2(0.0), float2(t), c);
    float2 u = smoothstep(float2(0.0), float2(t), 1.0 - c);
    return l.x * l.y * u.x * u.y;
}

static float mG(float hi, float lo, float t, float sh, float cv, float u_sharp, float u_scale) {
    sh *= (2.0 - u_sharp);
    float ci = smoothstep(0.15, 0.85, cv);
    float r = lo;
    float e1 = 0.08 / u_scale;
    r = mix(r, hi, smoothstep(0.0, sh * 1.5, t));
    r = mix(r, lo, smoothstep(e1 - sh, e1 + sh, t));
    float e2 = e1 + 0.05 / u_scale * (1.0 - ci * 0.35);
    r = mix(r, hi, smoothstep(e2 - sh, e2 + sh, t));
    float e3 = e2 + 0.025 / u_scale * (1.0 - ci * 0.45);
    r = mix(r, lo, smoothstep(e3 - sh, e3 + sh, t));
    float e4 = e1 + 0.1 / u_scale;
    r = mix(r, hi, smoothstep(e4 - sh, e4 + sh, t));
    float rm = 1.0 - e4;
    float gT = clamp((t - e4) / rm, 0.0, 1.0);
    r = mix(r, mix(hi, lo, smoothstep(0.0, 1.0, gT)), smoothstep(e4 - sh * 0.5, e4 + sh * 0.5, t));
    return r;
}

fragment float4 metallicPaintFragment(
    VertexOut in [[stage_in]],
    constant Uniforms& U [[buffer(0)]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float2 vP = in.vP;
    float3 sC = fract(float3(0.7548, 0.5698, 0.4154) * (U.u_seed + 17.31)) + 0.5;
    float3 sM = fract(sC.zxy - sC.yzx * 1.618);

    float2 sc = float2(vP.x * U.u_ratio, 1.0 - vP.y);
    float angleRad = U.u_angle * 3.14159 / 180.0;
    sc = rot(sc - 0.5, angleRad) + 0.5;
    sc = clamp(sc, 0.0, 1.0);
    float sl = sc.x - sc.y;
    float an = U.u_time * 0.001;
    float2 iC = fA(vP, U.u_ratio, U.u_imgRatio);
    float4 texSample = tex.sample(samp, iC);
    float dp = texSample.r;
    float shapeMask = texSample.a;
    float3 hi = U.u_lightColor * U.u_bright;
    float3 lo = U.u_darkColor * (2.0 - U.u_bright);
    lo.b += smoothstep(0.6, 1.4, sc.x + sc.y) * 0.08;
    float2 fC = sc - 0.5;
    float rd = length(fC + float2(0.0, sl * 0.15));
    float2 ag = rot(fC, (0.22 - sl * 0.18) * 3.14159);
    float cv = 1.0 - pow(rd * 1.65, 1.15);
    cv *= pow(sc.y, 0.35);
    float vs = shapeMask;
    vs *= bM(iC, 0.01);
    float fr = pow(1.0 - cv, U.u_fresnel) * 0.3;
    vs = min(vs + fr * vs, 1.0);
    float mT = an * 0.0625;
    float3 wO = float3(-1.05, 1.35, 1.55);
    float3 wA = aF(float3(31.0, 73.0, 56.0), mT + wO, sM) * 0.22 * U.u_wave;
    float3 wB = aF(float3(24.0, 64.0, 42.0), mT - wO.yzx, sM) * 0.22 * U.u_wave;
    float2 nC = sc * 45.0 * U.u_noise;
    nC += aF(sC.zxy, an * 0.17 * sC.yzx - sc.yxy * 0.35, sM).xy * 18.0 * U.u_wave;
    float3 tC = float3(0.00041, 0.00053, 0.00076) * mT + wB * nC.x + wA * nC.y;
    tC = lM(sC, tC, sM);
    tC = lM(sC + 1.618, tC, sM);
    float tb = sin(tC.x * 3.14159) * 0.5 + 0.5;
    tb = tb * 2.0 - 1.0;
    float noiseVal = perlinHelper(float3(sc * 8.0 + an, an * 0.5), sM).x;
    float edgeFactor = smoothstep(0.0, 0.5, dp) * smoothstep(1.0, 0.5, dp);
    float lD = dp + (1.0 - dp) * U.u_liquid * tb;
    lD += noiseVal * U.u_distort * 0.15 * edgeFactor;
    float rB = clamp(1.0 - cv, 0.0, 1.0);
    float fl = ag.x + sl;
    fl += noiseVal * sl * U.u_distort * edgeFactor;
    fl *= mix(1.0, 1.0 - dp * 0.5, U.u_contour);
    fl -= dp * U.u_contour * 0.8;
    float eI = smoothstep(0.0, 1.0, lD) * smoothstep(1.0, 0.0, lD);
    fl -= tb * sl * 1.8 * eI;
    float cA = cv * clamp(pow(sc.y, 0.12), 0.25, 1.0);
    fl *= 0.12 + (1.05 - lD) * cA;
    fl *= smoothstep(1.0, 0.65, lD);
    float vA1 = smoothstep(-0.08, 0.18, sc.y) * smoothstep(0.38, 0.18, sc.y);
    float vA2 = smoothstep(0.08, 0.18, 1.0 - sc.y) * smoothstep(0.38, 0.18, 1.0 - sc.y);
    fl += vA1 * 0.16 + vA2 * 0.025;
    fl *= 0.45 + pow(sc.y, 2.0) * 0.55;
    fl *= U.u_scale;
    fl -= an;
    float rO = rB + cv * tb * 0.025;
    float vM1 = smoothstep(-0.12, 0.18, sc.y) * smoothstep(0.48, 0.08, sc.y);
    float cM1 = smoothstep(0.35, 0.55, cv) * smoothstep(0.95, 0.35, cv);
    rO += vM1 * cM1 * 4.5;
    rO -= sl;
    float bO = rB * 1.25;
    float vM2 = smoothstep(-0.02, 0.35, sc.y) * smoothstep(0.75, 0.08, sc.y);
    float cM2 = smoothstep(0.35, 0.55, cv) * smoothstep(0.75, 0.35, cv);
    bO += vM2 * cM2 * 0.9;
    bO -= lD * 0.18;
    rO *= U.u_refract * U.u_chroma;
    bO *= U.u_refract * U.u_chroma;
    float sf = U.u_blur;
    float rP = fract(fl + rO);
    float rC = mG(hi.r, lo.r, rP, sf + 0.018 + U.u_refract * cv * 0.025, cv, U.u_sharp, U.u_scale);
    float gP = fract(fl);
    float gC = mG(hi.g, lo.g, gP, sf + 0.008 / max(0.01, 1.0 - sl), cv, U.u_sharp, U.u_scale);
    float bP = fract(fl - bO);
    float bC = mG(hi.b, lo.b, bP, sf + 0.008, cv, U.u_sharp, U.u_scale);
    float3 col = float3(rC, gC, bC);
    col = (col - 0.5) * U.u_contrast + 0.5;
    col = clamp(col, 0.0, 1.0);
    col = mix(col, 1.0 - min(float3(1.0), (1.0 - col) / max(U.u_tint, float3(0.001))), length(U.u_tint - 1.0) * 0.5);
    col = clamp(col, 0.0, 1.0);
    return float4(col * vs, vs);
}
