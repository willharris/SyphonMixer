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

struct FrameAnalysisData {
    var luminance: Float = -1.0
    var variance: Float = -1.0
    var edgeDensity: Float = -1.0
    var sumLum: Float = -1.0
    var sumLumSquared: Float = -1.0
    var sumEdges: Float = -1.0
    var maxEdge: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
}

enum VideoScalingMode: String, CaseIterable {
    case scaleToFit = "Scale to Fit"
    case scaleToFill = "Scale to Fill"
    case stretchToFill = "Stretch to Fill"
    case original = "Original Size"
}

struct FadeState {
    var isTransitioning: Bool = false
    var lastTransitionTime: TimeInterval = 0
    var targetAlpha: Float = 0.0  // Start with 0.0 as default
    var startAlpha: Float = 0.0
    var currentAlpha: Float = 0.0  // Track the current alpha
    var transitionStartTime: TimeInterval = 0
    var isFadedIn: Bool = false   // Track whether we're in a faded-in state
}

class SyphonRenderer {
    let logger = Logger()
    let device: MTLDevice
    let library: MTLLibrary
    let renderPipelineState: MTLRenderPipelineState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let frameAnalysisBuffer: MTLBuffer
    let luminancePipelineState: MTLComputePipelineState
    let computePipelineState: MTLComputePipelineState

    private let debugTestPattern = false
    private let logFreq = 30
    private var frameCount = 0
    private var currentColor = SIMD4<Float>(1.0, 0.0, 0.0, 1.0)
    private var hue: Float = 0.0
    private let formatter = DateFormatter()
    private let videoAnalyst = VideoAnalyst()
    
    // Auto-fade support
    private let fadeTransitionDuration: TimeInterval = 3.0
    private let minimumTransitionInterval: TimeInterval = 15.0
    private let fadeConfidenceThreshold: Float = 0.8
    private var fadeStates: [ObjectIdentifier: FadeState] = [:]
    private var lastFrameTime: TimeInterval = 0

    // Support scaling for video
    private var viewportSize: SIMD2<Float> = SIMD2<Float>(1, 1)

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
        
        var frameAnalysisData = FrameAnalysisData()
        frameAnalysisBuffer = device.makeBuffer(bytes: &frameAnalysisData,
                                                length: MemoryLayout<FrameAnalysisData>.size,
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
        let analyzeTextureFunction = library.makeFunction(name: "analyze_texture")!

        luminancePipelineState = try! device.makeComputePipelineState(function: luminanceFunction)
        computePipelineState = try! device.makeComputePipelineState(function: analyzeTextureFunction)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        let vertexDescriptor = MTLVertexDescriptor()
        // Position attribute
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        
        // Texture coordinate attribute
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 4
        vertexDescriptor.attributes[1].bufferIndex = 0
        
        // Viewport size attribute
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = 0
        vertexDescriptor.attributes[2].bufferIndex = 1
        
        // Define layouts
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.stride * 6  // position + texcoord
        vertexDescriptor.layouts[1].stride = MemoryLayout<SIMD2<Float>>.stride  // viewport size
        
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add

        renderPipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    
    private func updateFadeState(for textureId: ObjectIdentifier,
                                 fadeAnalysis: FadeAnalysis,
                                 streamAlpha: Float,
                                 stream: SyphonStream) -> Float {
         let currentTime = Date().timeIntervalSince1970
         
         // Initialize fade state if needed
         if fadeStates[textureId] == nil {
             var initialState = FadeState()
             initialState.currentAlpha = 0.0  // Start faded out
             fadeStates[textureId] = initialState
         }
         
         guard var fadeState = fadeStates[textureId] else { return 0.0 }
         
         // If not transitioning, check if we should start a new transition
         if !fadeState.isTransitioning {
             let timeSinceLastTransition = currentTime - fadeState.lastTransitionTime
             
             if fadeAnalysis.confidence >= fadeConfidenceThreshold &&
                timeSinceLastTransition >= minimumTransitionInterval {
                 
                 // Only start fade-in if we're not already faded in
                 let canStartFadeIn = fadeAnalysis.type == .fadeIn && !fadeState.isFadedIn
                 // Only start fade-out if we're currently faded in
                 let canStartFadeOut = fadeAnalysis.type == .fadeOut && fadeState.isFadedIn
                 
                 if canStartFadeIn || canStartFadeOut {
                     fadeState.isTransitioning = true
                     fadeState.lastTransitionTime = currentTime
                     fadeState.transitionStartTime = currentTime
                     fadeState.startAlpha = fadeState.currentAlpha  // Use current tracked alpha
                     fadeState.targetAlpha = fadeAnalysis.type == .fadeIn ? 1.0 : 0.0
                     fadeStates[textureId] = fadeState
                     
                     return fadeState.currentAlpha // Return current alpha for first frame
                 }
             }
             
             // If not transitioning, maintain current state
             return fadeState.currentAlpha
         }
         
         // If we're transitioning, update the alpha value
         let elapsedTime = currentTime - fadeState.transitionStartTime
         
         if elapsedTime >= fadeTransitionDuration {
             // Transition complete
             fadeState.isTransitioning = false
             fadeState.isFadedIn = fadeState.targetAlpha > 0.5
             fadeState.currentAlpha = fadeState.targetAlpha  // Update current alpha
             fadeStates[textureId] = fadeState
             return fadeState.currentAlpha
         } else {
             // Calculate interpolated alpha
             let progress = min(1.0, Float(elapsedTime / fadeTransitionDuration))
             let newAlpha = fadeState.startAlpha + (fadeState.targetAlpha - fadeState.startAlpha) * progress
             
             // Update current alpha
             fadeState.currentAlpha = newAlpha
             fadeStates[textureId] = fadeState
             
             return newAlpha
         }
    }
    
    func updateViewportSize(width: Float, height: Float) {
        viewportSize = SIMD2<Float>(width, height)
    }
    
    private func calculateLuminanceVariance(
        texture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        let width: UInt32 = UInt32(texture.width)
        let height: UInt32 = UInt32(texture.height)
        
        let frameAnalysisPointer = frameAnalysisBuffer.contents().bindMemory(
            to: FrameAnalysisData.self,
            capacity: 1
        )
        frameAnalysisPointer.pointee.width = width
        frameAnalysisPointer.pointee.height = height
        
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        computeEncoder.setComputePipelineState(computePipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(frameAnalysisBuffer, offset: 0, index: 0)
        
        let threadGroupWidth = 16
        let threadGroupHeight = 16
        let threadsPerGroup = MTLSizeMake(
            threadGroupWidth,
            threadGroupHeight,
            1
        )
        let numThreadgroups = MTLSizeMake(
            (texture.width + threadGroupWidth - 1) / threadGroupWidth,
            (texture.height + threadGroupHeight - 1) / threadGroupHeight,
            1
        )
        
        computeEncoder.dispatchThreadgroups(
            numThreadgroups,
            threadsPerThreadgroup: threadsPerGroup
        )
        
        computeEncoder.endEncoding()
    }
 
    private func calculateScalingTransform(textureSize: SIMD2<Float>, scalingMode: VideoScalingMode) -> [Float] {
        let textureAspect = textureSize.x / textureSize.y
        let viewAspect = viewportSize.x / viewportSize.y
        
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
        
        switch scalingMode {
        case .scaleToFit:
            if textureAspect > viewAspect {
                // Fit to width
                scaleX = 1.0
                scaleY = viewAspect / textureAspect
            } else {
                // Fit to height
                scaleX = textureAspect / viewAspect
                scaleY = 1.0
            }
            
        case .scaleToFill:
            if textureAspect > viewAspect {
                // Fill height
                scaleX = textureAspect / viewAspect
                scaleY = 1.0
            } else {
                // Fill width
                scaleX = 1.0
                scaleY = viewAspect / textureAspect
            }
            
        case .stretchToFill:
            scaleX = 1.0
            scaleY = 1.0
            
        case .original:
            scaleX = textureSize.x / viewportSize.x
            scaleY = textureSize.y / viewportSize.y
        }
        
        // Create vertex data for a fullscreen quad with scaling
        return [
            -scaleX, -scaleY, 0.0, 1.0,  0.0, 1.0,
             scaleX, -scaleY, 0.0, 1.0,  1.0, 1.0,
             scaleX,  scaleY, 0.0, 1.0,  1.0, 0.0,
            -scaleX,  scaleY, 0.0, 1.0,  0.0, 0.0
        ]
    }

    private func logFadeTransition(_ fadeAnalysis: FadeAnalysis, for textureId: ObjectIdentifier, luminance: Float, variance: Float, edgeDensity: Float) {
        let now = Date()
        print("""
        \(formatter.string(from: now)) \
        Frame: \(frameCount) \
        / 🎬 \(fadeAnalysis.type.description) \
        / Brightness: \(String(format:"%.1f%%", luminance * 100)) \
        / Variance: \(String(format:"%.1f%%", variance * 100)) \
        / Edge density: \(String(format:"%.1f%%", edgeDensity)) \
        / Confidence: \(String(format:"%.1f%%", fadeAnalysis.confidence * 100)) \
        / Rate: \(String(format:"%.2f%%", fadeAnalysis.averageRate * 100))/frame
        """)
    }

    func render(streams: [SyphonStream],
                in view: MTKView,
                commandQueue: MTLCommandQueue,
                renderPassDescriptor: MTLRenderPassDescriptor) -> MTLCommandBuffer
    {
        var textures = streams.compactMap { stream -> [String: Any]? in
            guard let client = stream.client,
                  let texture = client.newFrameImage() else {
                return nil
            }
            return ["tex": texture,
                    "alpha": Float(stream.alpha),
                    "scalingMode": stream.scalingMode,
                    "autoFade": stream.autoFade,
                    "stream": stream]
        }
        
        // Process luminance calculations
        if !textures.isEmpty {
            
            updateViewportSize(
                    width: Float(view.drawableSize.width),
                    height: Float(view.drawableSize.height)
            )
            
            for i in 0..<textures.count {
                let tex = textures[i]["tex"] as! MTLTexture
                
                // Get luminance value from buffer
                let frameAnalysisPointer = frameAnalysisBuffer.contents().bindMemory(
                    to: FrameAnalysisData.self,
                    capacity: 1
                )

                frameAnalysisPointer.pointee.luminance = 0.0
                frameAnalysisPointer.pointee.variance = 0.0
                frameAnalysisPointer.pointee.edgeDensity = 0.0
                frameAnalysisPointer.pointee.sumLum = 0.0
                frameAnalysisPointer.pointee.sumLumSquared = 0.0
                frameAnalysisPointer.pointee.sumEdges = 0.0
                frameAnalysisPointer.pointee.width = UInt32(tex.width)
                frameAnalysisPointer.pointee.height = UInt32(tex.height)
                
                let computeCommandBuffer = commandQueue.makeCommandBuffer()!
                
                calculateLuminanceVariance(texture: tex, commandBuffer: computeCommandBuffer)
                
                computeCommandBuffer.commit()
                computeCommandBuffer.waitUntilCompleted()
        
                // Calculate variance
                let totalPixels = Float(frameAnalysisPointer.pointee.width * frameAnalysisPointer.pointee.height)
                let sumLum = frameAnalysisPointer.pointee.sumLum
                let sumLumSquared = frameAnalysisPointer.pointee.sumLumSquared
                
                let meanLum = sumLum / totalPixels
                let meanLumSquared = sumLumSquared / totalPixels
        
                let variance = max(0, meanLumSquared - (meanLum * meanLum))
                
                let luminance = sumLum / totalPixels
                
                let sumEdges = frameAnalysisPointer.pointee.sumEdges
                let edgeDensity = sumEdges / totalPixels
                
                // Update rolling statistics
                let textureId = ObjectIdentifier(tex)
                videoAnalyst.updateStats(textureId: textureId, luminance: luminance, variance: variance, edgeDensity: edgeDensity)

                textures[i]["lum"] = luminance
                textures[i]["var"] = variance
                textures[i]["edge"] = edgeDensity
                textures[i]["id"] = textureId
            }
        }
        
        let renderCommandBuffer = commandQueue.makeCommandBuffer()!
        
        // Render textures
        let renderEncoder = renderCommandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(renderPipelineState)
        
        if debugTestPattern {
            _setTestPatternColour()
            _doRender(renderEncoder, bytes: &currentColor, length: MemoryLayout<SIMD4<Float>>.stride)
        } else {
            for texture in textures {
                let tex = texture["tex"] as! MTLTexture
                var alpha = texture["alpha"] as! Float
                let luminance = texture["lum"] as! Float
                let variance = texture["var"] as! Float
                let edgeDensity = texture["edge"] as! Float
                let stream = texture["stream"] as! SyphonStream
                let scalingMode = texture["scalingMode"] as! VideoScalingMode
                let autoFade = texture["autoFade"] as! Bool
                let textureId = texture["id"] as! ObjectIdentifier

                // Check for fade state changes
                let fadeAnalysis = videoAnalyst.analyzeFade(for: textureId, frameCount: frameCount)
                                
                // Update alpha if auto-fade is enabled
                if autoFade {
                    alpha = updateFadeState(for: textureId,
                                            fadeAnalysis: fadeAnalysis,
                                            streamAlpha: alpha,
                                            stream: stream)
//                    if frameCount % logFreq == 0 {
//                        print("\(frameCount) - \(stream.serverName) - Auto-fade: \(alpha)")
//                    }
                } else {
//                    if frameCount % logFreq == 0 {
//                        print("\(frameCount) - \(stream.serverName) - Manual fade: \(alpha)")
//                    }
                }

                // Fade state update and logging
                // Log only when fade state changes
                if let lastAnalysis = videoAnalyst.getLastFadeState(for: textureId) {
                    if fadeAnalysis.type != lastAnalysis.type {
                        logFadeTransition(fadeAnalysis, for: textureId, luminance: luminance, variance: variance, edgeDensity: edgeDensity)
                    }
                } else if fadeAnalysis.type != .none {
                    // Log initial fade detection
                    logFadeTransition(fadeAnalysis, for: textureId, luminance: luminance, variance: variance, edgeDensity: edgeDensity)
                }
//                if fadeAnalysis.type != .none {
//                    // Log initial fade detection
//                    logFadeTransition(fadeAnalysis, for: textureId, luminance: luminance, variance: variance, edgeDensity: edgeDensity)
//                }
                videoAnalyst.updateLastFadeState(fadeAnalysis, for: textureId)

                // Calculate scaling transform based on texture size
                let textureSize = SIMD2<Float>(Float(tex.width), Float(tex.height))
                let vertices = calculateScalingTransform(textureSize: textureSize, scalingMode: scalingMode)
                
                // Create a new vertex buffer with scaled coordinates
                let scaledVertexBuffer = device.makeBuffer(bytes: vertices,
                                                           length: vertices.count * MemoryLayout<Float>.stride,
                                                           options: [])!
                
                renderEncoder.setVertexBuffer(scaledVertexBuffer, offset: 0, index: 0)
                renderEncoder.setFragmentTexture(tex, index: 0)
                _doRender(renderEncoder, bytes: &alpha, length: MemoryLayout<Float>.stride)
            }
        }
        frameCount += 1

        renderEncoder.endEncoding()
        
        return renderCommandBuffer
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
    private func hsv2rgb(h: Float, s: Float, v: Float) -> SIMD4<Float> {
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
        
        return SIMD4<Float>(r + m, g + m, b + m, 1.0)
    }

    private func _doRender(_ renderEncoder: MTLRenderCommandEncoder, bytes: UnsafeRawPointer, length: Int) {
        // Set the fragment alpha/color
        renderEncoder.setFragmentBytes(bytes, length: length, index: 0)
        
        // Create and set the viewport size buffer
        var viewport = viewportSize
        renderEncoder.setVertexBytes(&viewport,
                                   length: MemoryLayout<SIMD2<Float>>.stride,
                                   index: 1)  // This matches bufferIndex: 1 in vertex descriptor
        

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: 6,
                                            indexType: .uint16,
                                            indexBuffer: indexBuffer,
                                            indexBufferOffset: 0)
     }
}
