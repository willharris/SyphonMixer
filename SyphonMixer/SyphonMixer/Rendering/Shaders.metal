//
//  Shaders.metal
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

#include <metal_stdlib>
using namespace metal;

//
// Vertex and fragment shaders
//

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float2 viewportSize [[attribute(2)]];
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

//
// Compute shaders
//

struct FrameAnalysisData {
    float luminance;
    float variance;
    float edgeDensity;
    atomic<float> sumLum;
    atomic<float> sumLumSquared;
    atomic<float> sumEdges;
    atomic<uint> maxEdge;
    uint width;
    uint height;
};

constant float3x3 sobelX = float3x3(
    -1.0, 0.0, 1.0,
    -2.0, 0.0, 2.0,
    -1.0, 0.0, 1.0
);

constant float3x3 sobelY = float3x3(
    -1.0, -2.0, -1.0,
     0.0,  0.0,  0.0,
     1.0,  2.0,  1.0
);

// Helper to get luminance for a pixel
float getLuminance(float4 color) {
    // Compute luminance using Rec. 709 coefficients
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

// Compute Sobel edge magnitude for a pixel
float computeEdgeMagnitude(texture2d<float, access::read> tex, uint2 pos, uint width, uint height) {
    float gx = 0.0;
    float gy = 0.0;
    
    // Apply Sobel operators
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            uint2 samplePos = uint2(
                clamp(pos.x + j, 0u, width - 1),
                clamp(pos.y + i, 0u, height - 1)
            );
            
            float lum = getLuminance(tex.read(samplePos));
            
            gx += lum * sobelX[i+1][j+1];
            gy += lum * sobelY[i+1][j+1];
        }
    }
    
    return sqrt(gx * gx + gy * gy);
}

// Currently only one compute kernel is supported
kernel void compute_luminance(texture2d<float, access::sample> inputTexture [[ texture(0) ]],
                              device FrameAnalysisData &luminanceData [[ buffer(0) ]],
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
        luminanceData.luminance = luminance; // Write the computed luminance
    }
}

kernel void analyze_texture(
    texture2d<float, access::read> inTexture [[texture(0)]],
    device FrameAnalysisData &frameAnalysisData [[buffer(0)]],
    uint3 tid [[thread_position_in_grid]],
    uint3 tpt [[thread_position_in_threadgroup]],
    uint3 tpg [[threads_per_threadgroup]]
) {
    // Compute scalar thread index within the threadgroup
    uint threadIndex = tpt.z * (tpg.x * tpg.y) + tpt.y * tpg.x + tpt.x;

    // Compute total threads per threadgroup
    uint threadsPerGroup = tpg.x * tpg.y * tpg.z;

    // Define maximum threadgroup size (adjust if necessary)
    constexpr uint maxThreadgroupSize = 256;

    // Ensure threadgroup arrays are correctly sized
    threadgroup float partialSumLum[maxThreadgroupSize];
    threadgroup float partialSumLumSquared[maxThreadgroupSize];
    threadgroup float partialSumEdges[maxThreadgroupSize];

    // Initialize partial sums
    float localSumLum = 0.0;
    float localSumLumSquared = 0.0;
    float localSumEdges = 0.0;

    // Check if the thread is within texture bounds
    if (tid.x < frameAnalysisData.width && tid.y < frameAnalysisData.height) {
        // Read the pixel color
        float4 color = inTexture.read(uint2(tid.x, tid.y));
        float luminance = getLuminance(color);
        
        // Compute edge magnitude
        float edgeMagnitude = computeEdgeMagnitude(inTexture, uint2(tid.x, tid.y),
                                                   frameAnalysisData.width, frameAnalysisData.height);
                
        // Threshold the edge magnitude to reduce noise
        const float edgeThreshold = 0.02; // 5% gradient
        float isEdge = edgeMagnitude > edgeThreshold ? 1.0 : 0.0;
        
        // Accumulate local sums
        localSumLum += luminance;
        localSumLumSquared += luminance * luminance;
        localSumEdges += isEdge;
    }

    // Store local sums in threadgroup memory
    partialSumLum[threadIndex] = localSumLum;
    partialSumLumSquared[threadIndex] = localSumLumSquared;
    partialSumEdges[threadIndex] = localSumEdges;

    // Synchronize threads within the threadgroup
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Perform reduction within the threadgroup
    uint halfThreads = threadsPerGroup / 2;
    while (halfThreads > 0) {
        if (threadIndex < halfThreads) {
            partialSumLum[threadIndex] += partialSumLum[threadIndex + halfThreads];
            partialSumLumSquared[threadIndex] += partialSumLumSquared[threadIndex + halfThreads];
            partialSumEdges[threadIndex] += partialSumEdges[threadIndex + halfThreads];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        halfThreads /= 2;
    }

    // First thread in the threadgroup writes the partial sums to atomic accumulators
    if (threadIndex == 0) {
        atomic_fetch_add_explicit(&frameAnalysisData.sumLum, partialSumLum[0], memory_order_relaxed);
        atomic_fetch_add_explicit(&frameAnalysisData.sumLumSquared, partialSumLumSquared[0], memory_order_relaxed);
        atomic_fetch_add_explicit(&frameAnalysisData.sumEdges, partialSumEdges[0], memory_order_relaxed);
    }
}
