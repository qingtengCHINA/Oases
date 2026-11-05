// SwiftUI Shader-API stitchable functions for the streaming response
// metallic shimmer. iOS 17+ exposes these via `Shader(function:arguments:)`
// and `.colorEffect()` / `.layerEffect()` on any View.
//
// The shimmer pass tints the assistant text with a moving diagonal
// metallic band — like brushed steel under a swept light source — only
// while the response is actively streaming. Once the stream completes
// the modifier is removed and the bubble renders flat again.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// Soft 1‑D ridge: 1.0 inside the band, falling to 0 outside.
static float bandRidge(float x, float width) {
    float a = max(0.0, 1.0 - abs(x) / max(width, 0.0001));
    return a * a * (3.0 - 2.0 * a);
}

// `streamShimmer` — colorEffect signature: (position, sourceColor) -> color.
//   `time` is the elapsed CACurrentMediaTime seconds (host-supplied)
//   `size` is the view bounds in points (host-supplied)
//   `tint` is the brand primary as (r, g, b) — passed so the highlight
//          matches the current mode's metallic colour.
[[ stitchable ]]
half4 streamShimmer(float2 position,
                    half4 currentColor,
                    float time,
                    float2 size,
                    float3 tint) {
    // Skip work on transparent pixels (text gutter / line gaps) — those
    // shouldn't accumulate the metallic tint.
    if (currentColor.a < 0.01) {
        return currentColor;
    }

    // Diagonal coordinate: x rolling, slight y influence so the band
    // angles ~15° off vertical, looks more brushed-metal than a slab.
    float u = (position.x + position.y * 0.18) / max(size.x, 1.0);

    // Two passes at different speeds for a richer "depth of light" feel.
    float speed1 = 0.45;
    float speed2 = 0.27;
    float band1 = bandRidge(fract(u - time * speed1) - 0.5, 0.18);
    float band2 = bandRidge(fract(u * 0.6 - time * speed2 + 0.31) - 0.5, 0.26);

    float highlight = clamp(band1 * 0.55 + band2 * 0.30, 0.0, 1.0);

    // Blend toward the tint, biased toward white so dark text still
    // gets a visible sheen. `mix` preserves alpha from the source.
    half3 sheen = half3(half3(tint) * 0.6 + half3(0.7));
    half3 outRGB = mix(currentColor.rgb, sheen, half(highlight) * 0.55h);
    return half4(outRGB, currentColor.a);
}
