//
//  SyphonRenderer.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//
import os

import Metal
import Syphon
import MetalKit

struct LuminanceData {
    var luminance: Float = -1.0
    var variance: Float = -1.0
    var sumLum: Float = -1.0
    var sumLumSquared: Float = -1.0
    var width: UInt32 = 0
    var height: UInt32 = 0
}

class SyphonRenderer {
    let logger = Logger()
    let device: MTLDevice
    let library: MTLLibrary
    let renderPipelineState: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let luminanceBuffer: MTLBuffer
    let luminancePipelineState: MTLComputePipelineState
    let luminanceVariancePipelineState: MTLComputePipelineState

    private let debugTestPattern = false
    private let logFreq = 30
    private var frameCount = 0
    private var currentColor = float4(1.0, 0.0, 0.0, 1.0)
    private var hue: Float = 0.0

    init(device: MTLDevice) {
        self.device = device
        
        // Create vertex data for a fullscreen quad
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,  0.0, 1.0,
             1.0, -1.0, 0.0, 1.0,  1.0, 1.0,
             1.0,  1.0, 0.0, 1.0,  1.0, 0.0,
            -1.0,  1.0, 0.0, 1.0,  0.0, 0.0
        ]
        
        let indices: [UInt16] = [
            0, 1, 2,
            0, 2, 3
        ]
        
        var luminanceData = LuminanceData()
        luminanceBuffer = device.makeBuffer(bytes: &luminanceData,
                                            length: MemoryLayout<LuminanceData>.size,
                                            options: .storageModeShared)!
        
       vertexBuffer = device.makeBuffer(bytes: vertices,
                                       length: vertices.count * MemoryLayout<Float>.stride,
                                       options: [])!
        
        indexBuffer = device.makeBuffer(bytes: indices,
                                      length: indices.count * MemoryLayout<UInt16>.stride,
                                      options: [])!
        
        // Create shader library and pipeline states
        self.library = device.makeDefaultLibrary()!
        
        // Setup render pipeline
        let vertexFunction = library.makeFunction(name: "vertex_main")
        let fragmentFunction = library.makeFunction(name: debugTestPattern ? "fragment_main_test" : "fragment_main")
        let luminanceFunction = library.makeFunction(name: "compute_luminance")!
        let luminanceVarianceFunction = library.makeFunction(name: "compute_luminance_variance")!

        luminancePipelineState = try! device.makeComputePipelineState(function: luminanceFunction)
        luminanceVariancePipelineState = try! device.makeComputePipelineState(function: luminanceVarianceFunction)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 4
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.stride * 6
        
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        renderPipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    private func calculateLuminance(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        computeEncoder.setComputePipelineState(luminancePipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(luminanceBuffer, offset: 0, index: 0)

        let w = texture.width
        let h = texture.height
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (w + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (h + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        
        computeEncoder.endEncoding()
   }
    
    private func calculateLuminanceVariance(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        var width: UInt32 = UInt32(texture.width)
        var height: UInt32 = UInt32(texture.height)
        let luminancePointer = luminanceBuffer.contents().bindMemory(
            to: LuminanceData.self,
            capacity: 1
        )
        luminancePointer.pointee.width = width
        luminancePointer.pointee.height = height
        
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        computeEncoder.setComputePipelineState(luminanceVariancePipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(luminanceBuffer, offset: 0, index: 0)
        
        let threadGroupWidth = 16
        let threadGroupHeight = 16
        let threadsPerGroup = MTLSizeMake(threadGroupWidth, threadGroupHeight, 1)
        let numThreadgroups = MTLSizeMake(
            (texture.width  + threadGroupWidth  - 1) / threadGroupWidth,
            (texture.height + threadGroupHeight - 1) / threadGroupHeight,
            1
        )
        
        computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerGroup)
        
        computeEncoder.endEncoding()
   }
 
    func computeLuminanceVarianceCPU(texture: MTLTexture) -> Float {
        // 1. Get texture size
        let width = texture.width
        let height = texture.height
        let pixelCount = width * height

        // 2. Prepare buffer to receive texture data
        let bytesPerPixel = 4 * MemoryLayout<UInt8>.size // 4 components, 8 bits each
        let bytesPerRow = bytesPerPixel * width
        let dataSize = bytesPerRow * height
        var pixelData = [UInt8](repeating: 0, count: dataSize)

        // 3. Create region to copy
        let region = MTLRegionMake2D(0, 0, width, height)

        // 4. Copy texture data to CPU-accessible buffer
        texture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // 5. Compute luminance values and accumulate sums
        var sumLum: Float = 0.0
        var sumLumSquared: Float = 0.0

        for i in stride(from: 0, to: pixelData.count, by: 4) {
            // Ensure indices are within bounds
            guard i + 3 < pixelData.count else {
                print("Index out of bounds at position \(i)")
                break
            }

            // Read pixel components based on pixel format
            let r, g, b: Float

            if texture.pixelFormat == .bgra8Unorm {
                b = Float(pixelData[i]) / 255.0
                g = Float(pixelData[i + 1]) / 255.0
                r = Float(pixelData[i + 2]) / 255.0
                // Alpha channel is pixelData[i + 3] if needed
            } else if texture.pixelFormat == .rgba8Unorm {
                r = Float(pixelData[i]) / 255.0
                g = Float(pixelData[i + 1]) / 255.0
                b = Float(pixelData[i + 2]) / 255.0
                // Alpha channel is pixelData[i + 3] if needed
            } else {
                print("Unsupported pixel format")
                return 0.0
            }

            // Compute luminance
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b

            sumLum += luminance
            sumLumSquared += luminance * luminance
        }

        let totalPixels = Float(pixelCount)
        if totalPixels > 0 {
            let meanLum = sumLum / totalPixels
            let meanLumSquared = sumLumSquared / totalPixels

            let variance = meanLumSquared - (meanLum * meanLum)
            return variance
        } else {
            print("Error: totalPixels is zero")
            return 0.0
        }
    }

    func render(streams: [SyphonStream],
                in view: MTKView,
                renderCommandBuffer: MTLCommandBuffer,
                renderPassDescriptor: MTLRenderPassDescriptor,
                computeCommandBuffer: MTLCommandBuffer)
    {
        var textures = streams.compactMap { stream -> [String: Any]? in
            guard let client = stream.client,
                  let texture = client.newFrameImage() else {
                return nil
            }
            return ["tex": texture, "alpha": Float(stream.alpha)]
        }
        
        // Process luminance calculations
        if !textures.isEmpty {
            for i in 0..<textures.count {
                let tex = textures[i]["tex"] as! MTLTexture
                calculateLuminance(texture: tex, commandBuffer: computeCommandBuffer)
                calculateLuminanceVariance(texture: tex, commandBuffer: computeCommandBuffer)
                
                computeCommandBuffer.commit()
                computeCommandBuffer.waitUntilCompleted()
        
                // Get luminance value from buffer
                let luminancePointer = luminanceBuffer.contents().bindMemory(
                    to: LuminanceData.self,
                    capacity: 1
                )
                let luminance = luminancePointer.pointee.luminance
        
                // Calculate variance
                let totalPixels = Float(luminancePointer.pointee.width * luminancePointer.pointee.height)
                let sumLum = luminancePointer.pointee.sumLum
                let sumLumSquared = luminancePointer.pointee.sumLumSquared
        
                let meanLum = sumLum / totalPixels
                let meanLumSquared = sumLumSquared / totalPixels
        
                let variance = meanLumSquared - (meanLum * meanLum)
                
                textures[i]["lum"] = luminance
                textures[i]["var"] = variance
            }
        }
        
        // Render textures
        let renderEncoder = renderCommandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        if debugTestPattern {
            _setTestPatternColour()
            _doRender(renderEncoder, bytes: &currentColor, length: MemoryLayout<float4>.stride)
        } else {
            for texture in textures {
                let tex = texture["tex"] as! MTLTexture
                var alpha = texture["alpha"] as! Float
                let luminance = texture["lum"] as! Float
                let variance = texture["var"] as! Float

                if frameCount % logFreq == 0 {
                    print("\(ObjectIdentifier(tex)) alpha: \(alpha) lum: \(String(format:"%.4f", luminance)) var: \(String(format:"%.4f", variance))")
                }
                renderEncoder.setFragmentTexture(tex, index: 0)
                _doRender(renderEncoder, bytes: &alpha, length: MemoryLayout<Float>.stride)
            }
        }
        frameCount += 1

        renderEncoder.endEncoding()
    }
    
    // Create a test render method
    // Use "fragment_main_test" shader function to render a test pattern - set above as fragmentFunction
    private func _setTestPatternColour() {
        // Increment hue (0.0 to 1.0) each frame
        hue += 0.002  // Adjust this value to change sweep speed
        
        // Keep hue in 0.0 to 1.0 range
        if hue > 1.0 {
            hue -= 1.0
        }
        
        // Convert HSV to RGB
        currentColor = hsv2rgb(h: hue, s: 1.0, v: 1.0)
    }

    // Convert HSV to RGB color space
    private func hsv2rgb(h: Float, s: Float, v: Float) -> float4 {
        let c = v * s
        let x = c * (1 - abs(fmod(h * 6, 2) - 1))
        let m = v - c
        
        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        
        switch h * 6 {
        case 0..<1:
            r = c; g = x; b = 0
        case 1..<2:
            r = x; g = c; b = 0
        case 2..<3:
            r = 0; g = c; b = x
        case 3..<4:
            r = 0; g = x; b = c
        case 4..<5:
            r = x; g = 0; b = c
        default:
            r = c; g = 0; b = x
        }
        
        return float4(r + m, g + m, b + m, 1.0)
    }

    private func _doRender(_ renderEncoder: MTLRenderCommandEncoder, bytes: UnsafeRawPointer, length: Int) {
        renderEncoder.setFragmentBytes(bytes, length: length, index: 0)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: 6,
                                            indexType: .uint16,
                                            indexBuffer: indexBuffer,
                                            indexBufferOffset: 0)
     }
}
