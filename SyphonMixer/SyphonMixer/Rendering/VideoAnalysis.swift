//
//  VideoAnalysis.swift
//  SyphonMixer
//
//  Created by William Harris on 27.11.2024.
//
import Metal

func calculateLuminance(commandBuffer: MTLCommandBuffer, library: MTLLibrary, texture: MTLTexture) -> Float {
    let device = texture.device
    
    guard let luminanceFunction = library.makeFunction(name: "calculateLuminance") else {
        print("Failed to create luminance function")
        return 0.0
    }
    guard let computePipelineState = try? device.makeComputePipelineState(function: luminanceFunction) else {
        print("Failed to create compute pipeline state")
        return 0.0
    }
    print("Got past the guard")

    
    // Create output buffer for the result
    let resultBuffer = device.makeBuffer(
        length: MemoryLayout<Float>.size,
        options: .storageModeShared
    )!
    
    // Create command encoder
    guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
        return 0.0
    }
    
    computeEncoder.setComputePipelineState(computePipelineState)
    computeEncoder.setTexture(texture, index: 0)
    computeEncoder.setBuffer(resultBuffer, offset: 0, index: 0)
    
    // Calculate threadgroup size
    let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
    let threadGroups = MTLSize(
        width: (
            texture.width + threadGroupSize.width - 1
        ) / threadGroupSize.width,
        height: (
            texture.height + threadGroupSize.height - 1
        ) / threadGroupSize.height,
        depth: 1
    )
    
    computeEncoder
        .dispatchThreadgroups(
            threadGroups,
            threadsPerThreadgroup: threadGroupSize
        )
    computeEncoder.endEncoding()
    
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    
    return resultBuffer.contents().load(as: Float.self)
}
