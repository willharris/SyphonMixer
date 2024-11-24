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

class SyphonRenderer {
    let logger = Logger()
    
    let device: MTLDevice
    let pipelineState: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    
    private let debugTestPattern = false
    private var frameCount = 0
    private var currentColor = float4(1.0, 0.0, 0.0, 1.0)

    init(device: MTLDevice) {
        self.device = device
        
        // Create vertex data for a fullscreen quad
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,  0.0, 1.0, // bottom left
             1.0, -1.0, 0.0, 1.0,  1.0, 1.0, // bottom right
             1.0,  1.0, 0.0, 1.0,  1.0, 0.0, // top right
            -1.0,  1.0, 0.0, 1.0,  0.0, 0.0  // top left
        ]
        
        let indices: [UInt16] = [
            0, 1, 2,
            0, 2, 3
        ]
        
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                       length: vertices.count * MemoryLayout<Float>.stride,
                                       options: [])!
        
        indexBuffer = device.makeBuffer(bytes: indices,
                                      length: indices.count * MemoryLayout<UInt16>.stride,
                                      options: [])!
        
        // Create shader library and pipeline state
        let library = try! device.makeLibrary(source: MetalShaders.shaderSource, options: nil)
        let vertexFunction = library.makeFunction(name: "vertex_main")
        let fragmentFunction = library.makeFunction(name: debugTestPattern ? "fragment_main_test" : "fragment_main")
        
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
        
        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    func render(streams: [SyphonStream],
                in view: MTKView,
                commandBuffer: MTLCommandBuffer,
                renderPassDescriptor: MTLRenderPassDescriptor)
    {
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        frameCount += 1

        if debugTestPattern {
            _setTestPatternColour()
            _doRender(renderEncoder, bytes: &currentColor, length: MemoryLayout<float4>.stride)
        } else {
            // Render each stream
            for stream in streams {
                guard let client = stream.client else { continue }

                if let tex = client.newFrameImage() {
                    if frameCount % 120 == 0 {
                        print("\(self.frameCount): \(stream.serverName): \(ObjectIdentifier(client)) \(ObjectIdentifier(tex)): width: \(tex.width), height: \(tex.height)")
                    }
                    renderEncoder.setFragmentTexture(tex, index: 0)
                    var alpha = Float(stream.alpha)
                    _doRender(renderEncoder, bytes: &alpha, length: MemoryLayout<Float>.stride)
                } else {
                    print("Failed to get frame texture")
                }
            }
        }
        
        renderEncoder.endEncoding()
    }
    
    // Create a test render method
    // Use "fragment_main_test" shader function to render a test pattern - set above as fragmentFunction
    private func _setTestPatternColour() {
        // Change color every 60 frames
        if frameCount % 60 == 0 {
            currentColor = float4(
                Float.random(in: 0...1),
                Float.random(in: 0...1),
                Float.random(in: 0...1),
                1.0
            )
        }
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
