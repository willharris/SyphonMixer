//
//  Shaders.metal
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_main(const VertexIn vertex_in [[stage_in]]) {
    VertexOut out;
    out.position = vertex_in.position;
    out.texCoord = vertex_in.texCoord;
    return out;
}

fragment float4 fragment_main_test(constant float4 *color [[buffer(0)]]) {
    return *color;
}                        

fragment float4 fragment_main(VertexOut in [[stage_in]],
                            texture2d<float> texture [[texture(0)]],
                            constant float &alpha [[buffer(0)]])
{
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float2 flippedTexCoord = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    float4 color = texture.sample(textureSampler, flippedTexCoord);
    return float4(color.rgb, color.a * alpha);
}

kernel void compute_luminance(texture2d<float, access::sample> inputTexture [[ texture(0) ]],
                              device float *output [[ buffer(0) ]],
                              uint2 gid [[ thread_position_in_grid ]],
                              uint2 textureSize [[ threads_per_grid ]]) {
    // Normalize the gid based on the texture size
    float2 uv = float2(gid) / float2(textureSize);

    // Sample the texture to get the pixel color
    float4 pixelColor = inputTexture.sample(sampler(coord::normalized), uv);

    // Compute luminance (using standard formula)
    float luminance = 0.2126 * pixelColor.r + 0.7152 * pixelColor.g + 0.0722 * pixelColor.b;

    // Example: Write one luminance value (for gid 0,0 only, as a placeholder)
    if (gid.x == 0 && gid.y == 0) {
        *output = luminance; // Write the computed luminance
    }
}
