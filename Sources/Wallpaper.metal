#include <metal_stdlib>
using namespace metal;

struct WallpaperVertex {
    float4 position [[position]];
    float2 uv;
};
struct WallpaperUniforms {
    float2 canvas;
    float2 origin;
    float2 region;
    float2 image;
    float scale;
    uint dither;
};
vertex WallpaperVertex wallpaperVertex(uint index [[vertex_id]]) {
    constexpr float2 points[] = {float2(-1, -1), float2(-1, 3), float2(3, -1)};
    float2 point = points[index];
    return {float4(point, 0, 1), float2((point.x + 1) * 0.5, (1 - point.y) * 0.5)};
}
fragment float4 wallpaperFragment(WallpaperVertex in [[stage_in]],
                                   constant WallpaperUniforms &u [[buffer(0)]],
                                   texture2d<float> image [[texture(0)]]) {
    constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::linear);
    float fit = max(u.canvas.x / u.image.x, u.canvas.y / u.image.y);
    float2 fitted = u.image * fit;
    float2 point = u.origin + in.uv * u.region;
    float2 offset = (u.canvas - fitted) * 0.5;
    float4 color = image.sample(sampling, (point - offset) / fitted);
    if (u.dither != 0) {
        float pitch = max(2.0f, round(4 * u.scale));
        float dotSize = max(1.0f, round(1.5f * u.scale));
        float2 pixel = point * u.scale;
        int2 cell = int2(floor(pixel / pitch));
        float2 center = (float2(cell) * pitch + floor(pitch * 0.5)) / u.scale;
        float3 sample = image.sample(sampling, (center - offset) / fitted).rgb;
        float luminance = dot(sample, float3(54, 183, 19)) / 256;
        constexpr int matrix[] = {0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5};
        float threshold = (matrix[(cell.y & 3) * 4 + (cell.x & 3)] * 255 + 127) / (255.0f * 16);
        float2 local = pixel - float2(cell) * pitch;
        float left = floor(pitch * 0.5) - floor(dotSize * 0.5);
        if (1 - luminance > threshold && all(local >= left) && all(local < left + dotSize)) {
            color.rgb = float3(14.0f / 255) + color.rgb / 5;
        }
    }
    return float4(color.rgb, 1);
}
