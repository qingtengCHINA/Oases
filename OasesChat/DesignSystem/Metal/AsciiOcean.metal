#include <metal_stdlib>
using namespace metal;

// Composes the Ogent ASCII ocean: every cell of the light field becomes a tinted tile plus a
// character from a 12-step density ramp. Mirrors `AsciiOceanUniforms` in AsciiOceanRenderer.swift
// (all float4 first, then float2, then float; 208 bytes).
struct AsciiOceanUniforms {
    float4 hueA;
    float4 hueB;
    float4 ink;        // light mode: the dark the characters lean toward
    float4 snow;       // rgb + max alpha
    float4 accent0;
    float4 accent1;
    float4 accent2;
    float4 accent3;
    float2 cellPx;     // one cell, in drawable pixels
    float2 grid;       // columns, rows
    float2 drawable;   // drawable size in pixels
    float2 fade;       // top / bottom fade, in pixels
    float  time;
    float  tickRate;   // character changes per second
    float  layerAlpha;
    float  glyphCap;
    float  tileScale;
    float  hot;        // 1: the brightest cells invert
    float  light;      // 1: light appearance
    float  gridAlpha;
    float  glyphCount; // glyphs in the atlas
    float  pad0;
    float  pad1;
    float  pad2;
};

struct OceanOut {
    float4 position [[position]];
};

vertex OceanOut asciiOceanVertex(uint vid [[vertex_id]]) {
    // One triangle that covers the screen.
    float2 p = float2((vid << 1) & 2, vid & 2);
    OceanOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static inline float oceanHash(uint x, uint y, uint t) {
    uint h = x * 0x8DA6B343u ^ y * 0xD8163841u ^ t * 0xCB1AB31Fu;
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    h ^= h >> 12;
    h *= 0x297A2D39u;
    h ^= h >> 15;
    return float(h) * (1.0 / 4294967296.0);
}

static inline float4 over(float4 top, float4 under) {
    // Premultiplied source-over.
    return top + under * (1.0 - top.a);
}

fragment float4 asciiOceanFragment(OceanOut in [[stage_in]],
                                   constant AsciiOceanUniforms& U [[buffer(0)]],
                                   texture2d<float, access::read> cells [[texture(0)]],
                                   texture2d<float> atlas [[texture(1)]],
                                   sampler atlasSampler [[sampler(0)]])
{
    float2 pos = in.position.xy;
    float2 g = pos / U.cellPx;
    uint2 c = uint2(g);
    if (c.x >= uint(U.grid.x) || c.y >= uint(U.grid.y)) { return float4(0); }
    float2 lc = fract(g);
    float2 px = lc * U.cellPx;
    float4 v = cells.read(c);
    float a = v.r, w = v.g, b = v.b;
    float L = min(1.0, a + b + 0.55 * w);

    float4 col = float4(0);
    float3 hair = U.light > 0.5 ? float3(0.0) : float3(1.0);
    if (px.x < 1.0 || px.y < 1.0) { col = float4(hair, 1.0) * U.gridAlpha; }

    float gw = 1.0 / U.glyphCount;
    if (L >= 0.055) {
        float tb = round(b / (a + b + 1e-4) * 5.0) / 5.0;
        int lv = min(11, int(L * 12.0));
        float wb = w < 0.12 ? 0.0 : (w < 0.32 ? 0.31 : 0.62);
        float3 base = mix(U.hueA.rgb, U.hueB.rgb, tb);
        bool hot = U.hot > 0.5 && lv >= 10 && wb > 0.0;

        // Tile (inset by about a pixel).
        bool inTile = lv >= 1 && px.x > 1.0 && px.y > 1.0 && px.x < U.cellPx.x - 1.0 && px.y < U.cellPx.y - 1.0;
        if (inTile) {
            float3 tileRGB;
            float tileA;
            if (U.light > 0.5) {
                tileRGB = hot ? U.ink.rgb : mix(base, float3(1.0), 0.55);
                tileA = hot ? 0.85 : (0.06 + 0.30 * L);
            } else {
                tileRGB = hot ? mix(base * 0.58, float3(0.925), 0.5 + 0.3 * wb) : base * 0.58;
                tileA = hot ? 0.9 : (0.1 + 0.5 * L);
            }
            tileA *= hot ? 1.0 : U.tileScale;
            col = over(float4(tileRGB * tileA, tileA), col);
        }

        // Character: each cell flips between two shapes on its own beat.
        uint tick = uint(floor(U.time * U.tickRate + float((c.x * 7u + c.y * 13u) & 15u) / 16.0));
        float h = oceanHash(c.x, c.y, tick);
        float gi = float(lv * 2 + (h < 0.55 ? 0 : 1));
        float cov = atlas.sample(atlasSampler, float2((gi + lc.x) * gw, lc.y)).r;

        float3 gRGB;
        float gA;
        float lift = clamp(0.12 + 0.5 * L + 0.34 * wb, 0.0, 0.94);
        if (hot) {
            gRGB = U.light > 0.5 ? float3(0.97) : float3(6.0, 10.0, 16.0) / 255.0;
            gA = 1.0;
        } else if (U.light > 0.5) {
            gRGB = mix(base * 0.6, U.ink.rgb, 0.35 + 0.4 * lift);
            gA = 0.4 + 0.6 * L;
        } else {
            gRGB = mix(base, float3(246.0 / 255.0), lift);
            gA = 0.4 + 0.6 * L;
        }
        if (!hot && lv >= 4 && lv < 10 && h > 0.988) {
            uint k = uint(h * 10000.0) & 3u;
            gRGB = k == 0u ? U.accent0.rgb : (k == 1u ? U.accent1.rgb : (k == 2u ? U.accent2.rgb : U.accent3.rgb));
        }
        gA = min(gA, hot ? 1.0 : U.glyphCap) * cov;
        col = over(float4(gRGB * gA, gA), col);
    } else if (v.a > 0.0) {
        // A flake of snow drifting through the dark cells.
        uint code = uint(round(v.a * 255.0));
        float glyph = float(24u + ((code >> 5) & 7u) - 1u);
        float alpha = float(code & 31u) / 31.0 * U.snow.a;
        float cov = atlas.sample(atlasSampler, float2((glyph + lc.x) * gw, lc.y)).r;
        float sa = alpha * cov;
        col = over(float4(U.snow.rgb * sa, sa), col);
    }

    // Soft vignette and fades at the top and bottom edges.
    float2 uv = pos / U.drawable;
    float2 q = (uv - float2(0.5, 0.45)) / float2(1.4, 1.2);
    float vig = 1.0 - 0.45 * smoothstep(0.28, 0.6, length(q));
    float top = U.fade.x > 0.0 ? smoothstep(0.0, U.fade.x, pos.y) : 1.0;
    float bottom = U.fade.y > 0.0 ? smoothstep(0.0, U.fade.y, U.drawable.y - pos.y) : 1.0;
    return col * (U.layerAlpha * vig * top * bottom);
}
