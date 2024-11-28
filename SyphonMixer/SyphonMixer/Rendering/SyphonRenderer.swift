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
    var totalLuminance: Float = 0.0
    var pixelCount: UInt32 = 0
    var debugMaxLuminance: Float = 0.0
    var debugMinLuminance: Float = 0.0
    var debugWidth: UInt32 = 0
    var debugHeight: UInt32 = 0
}

class SyphonRenderer {
    let logger = Logger()
    let device: MTLDevice
    let library: MTLLibrary
    let renderPipelineState: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let luminanceBuffer: MTLBuffer
    let computePipelineState: MTLComputePipelineState
    
    private let debugTestPattern = false
    private let logFreq = 120
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
        
        var luminance: Float = 0.0
        luminanceBuffer = device.makeBuffer(bytes: &luminance,
                                            length: MemoryLayout<Float>.size,
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
        
        computePipelineState = try! device.makeComputePipelineState(function: luminanceFunction)
        
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
    
    private func calculateLuminance(texture: MTLTexture, commandBuffer: MTLCommandBuffer) -> Float {
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        computeEncoder.setComputePipelineState(computePipelineState)
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
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let luminancePointer = luminanceBuffer.contents().bindMemory(to: Float.self, capacity: 1)
        let luminance = luminancePointer.pointee
        return luminance
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
                let lum = calculateLuminance(texture: tex, commandBuffer: computeCommandBuffer)
                textures[i]["lum"] = lum
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
                let lum = texture["lum"] as! Float
                
                if frameCount % logFreq == 0 {
                    print("\(ObjectIdentifier(tex)) alpha: \(alpha) lum: \(lum)")
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
