// Stitchable Metal fragment for the empty-state aurora field. Replaces
// the static RadialGradient behind EmptyGreeting with a slow flowing
// nebula tinted by the active mode's metallic colour.
//
// Used via SwiftUI iOS 17+ `.colorEffect(ShaderLibrary.aurora(...))`.
// Signature follows the colorEffect convention:
//   (position, sourceColor) -> half4
// with extra uniforms tail-attached: time, size, tint.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// 32-bit hash → unit float. Cheap, good enough for noise.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// 2D value noise with smoothed interpolation.
static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 4-octave fractional Brownian motion — soft cloud-like field.
static float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * valueNoise(p);
        p *= 2.05;
        amp *= 0.5;
    }
    return v;
}

[[ stitchable ]]
half4 aurora(float2 position,
             half4 currentColor,
             float time,
             float2 size,
             float3 tint) {
    // Normalised coordinates with a gentle aspect correction so the
    // nebula reads the same in portrait and landscape.
    float2 uv = position / max(size, float2(1.0));
    uv.x *= size.x / max(size.y, 1.0);

    // Two domain-warped fbm passes drifting at different speeds — gives
    // the field a sense of depth without ever repeating visibly.
    float2 q = float2(
        fbm(uv * 1.6 + float2(time * 0.04, 0.0)),
        fbm(uv * 1.6 + float2(5.2, time * 0.05))
    );
    float n = fbm(uv * 2.4 + q * 1.8 + time * 0.025);

    // Soft vignette so the brightest bands stay near the top — matches
    // the original RadialGradient(center: (0.5, -0.1)) composition.
    float vy = 1.0 - smoothstep(0.0, 1.2, length(uv - float2(uv.x, -0.1)));
    float field = smoothstep(0.20, 0.85, n) * vy;

    // Two-stop tint mix: deep tint at the band centres, near-black at
    // the edges. Multiply by 0.42 so the aurora never overwhelms the
    // foreground text.
    half3 colour = mix(half3(0.0), half3(half3(tint)), half(field) * 0.42h);

    // Composite OVER the existing background colour (whatever SwiftUI
    // hands us). The original background stays underneath at full
    // opacity; the aurora adds light on top.
    half3 outRGB = clamp(half3(currentColor.rgb) + colour, half3(0.0), half3(1.0));
    return half4(outRGB, currentColor.a);
}
