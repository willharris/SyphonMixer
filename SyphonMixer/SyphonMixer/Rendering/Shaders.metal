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

struct LuminanceData {
    atomic_float totalLuminance;
    atomic_uint pixelCount;
    float debugMaxLuminance;  // Add debug values
    float debugMinLuminance;
    uint debugWidth;
    uint debugHeight;
};

kernel void calculateLuminance(texture2d<float, access::read> inputTexture [[texture(0)]],
                             device LuminanceData* data [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    float4 color = inputTexture.read(gid);
    float pixelLuminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    
    // Store debug info for the first thread
    if (gid.x == 0 && gid.y == 0) {
        data->debugWidth = inputTexture.get_width();
        data->debugHeight = inputTexture.get_height();
        data->debugMaxLuminance = -1.0;
        data->debugMinLuminance = 1000.0;
    }
    
    atomic_fetch_add_explicit(&data->totalLuminance, pixelLuminance, memory_order_relaxed);
    atomic_fetch_add_explicit(&data->pixelCount, 1u, memory_order_relaxed);
}
