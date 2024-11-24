//
//  File.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import Metal

enum MetalShaders {
    static let shaderSource = """
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
    """
}
