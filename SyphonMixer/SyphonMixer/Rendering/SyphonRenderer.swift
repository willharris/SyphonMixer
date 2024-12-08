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

struct FrameStats {
    let luminance: Float
    let variance: Float
    let edgeDensity: Float
    let frameIndex: Int
}

struct FadeAnalysis {
    enum FadeType {
        case none
        case fadeIn
        case fadeOut
        
        var description: String {
            switch self {
            case .none: return "No fade"
            case .fadeIn: return "Fade IN"
            case .fadeOut: return "Fade OUT"
            }
        }
    }
    
    let type: FadeType
    let confidence: Float  // 0-1 indicating how confident we are this is a fade
    let averageRate: Float  // Average rate of change per frame
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

    // Statistical tracking with thread safety
    private let ROLLING_WINDOW = 120
    private var frameStats: [ObjectIdentifier: [FrameStats]] = [:]
    private let statsQueue = DispatchQueue(label: "com.syphonmixer.stats")
    private var frameIndices: [ObjectIdentifier: Int] = [:]

    // Fade detection parameters
    private let FADE_THRESHOLD: Float = 0.0008  // Detect 0.1% changes per frame
    private let FADE_CONSISTENCY_THRESHOLD: Float = 0.40  // Consistency threshold for fade detection
    private let MIN_FADE_FRAMES = 30  // Minimum number of frames to analyze
    private let fadeStateQueue = DispatchQueue(label: "com.syphonmixer.fadestate")

    // Track previous fade state per texture
    private var lastFadeState: [ObjectIdentifier: FadeAnalysis] = [:]

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
        
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    
    // Thread-safe accessors for state
    private func getFrameStats(for textureId: ObjectIdentifier) -> [FrameStats]? {
        var result: [FrameStats]?
        statsQueue.sync {
            result = frameStats[textureId]
        }
        return result
    }

    private func getCurrentFrameIndex(for textureId: ObjectIdentifier) -> Int {
        var result: Int = 0
        statsQueue.sync {
            result = frameIndices[textureId] ?? 0
        }
        return result
    }

    private func updateLastFadeState(_ analysis: FadeAnalysis, for textureId: ObjectIdentifier) {
        fadeStateQueue.async {
            self.lastFadeState[textureId] = analysis
        }
    }

    private func getLastFadeState(for textureId: ObjectIdentifier) -> FadeAnalysis? {
        var result: FadeAnalysis?
        fadeStateQueue.sync {
            result = lastFadeState[textureId]
        }
        return result
    }
    
    private func analyzeFade(for textureId: ObjectIdentifier) -> FadeAnalysis {
        var localStats: [FrameStats]?
        statsQueue.sync {
            localStats = frameStats[textureId]
        }
        
        guard let stats = localStats,
              stats.count >= MIN_FADE_FRAMES else {
            return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
        }
        
        let luminances = stats.map { $0.luminance }
        let variances = stats.map { $0.variance }
//        let edgeDensities = stats.map { $0.edgeDensity }

        // Calculate total changes
        let totalLumChange = abs(luminances.last! - luminances.first!)
//        let totalVarChange = abs(variances.last! - variances.first!)
        
        let previousAnalysis = getLastFadeState(for: textureId)
        
        // Early exit if total change is too small
        if totalLumChange < FADE_THRESHOLD * Float(MIN_FADE_FRAMES) * 0.5 {
            if previousAnalysis?.type != FadeAnalysis.FadeType.none {
                let now = Date()
                print("\(formatter.string(from: now))--> None: totalLumChange \(totalLumChange) < \(FADE_THRESHOLD * Float(MIN_FADE_FRAMES) * 0.5)")
            }
            
            return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
        }
        
        // Calculate frame-to-frame changes
        var lumChanges: [Float] = []
        var varChanges: [Float] = []
        for i in 1..<stats.count {
            lumChanges.append(luminances[i] - luminances[i-1])
            varChanges.append(variances[i] - variances[i-1])
        }
        
        let avgLumChange = lumChanges.reduce(0, +) / Float(lumChanges.count)
        let avgVarChange = varChanges.reduce(0, +) / Float(varChanges.count)
        
        // Check if luminance and variance are changing in the same direction
        let sameDirection = (avgLumChange > 0 && avgVarChange > 0) ||
                           (avgLumChange < 0 && avgVarChange < 0)
        
        // Calculate consistency of changes
        let consistentLumChanges = lumChanges.filter { change in
            return abs(change) >= FADE_THRESHOLD * 0.8 &&
                   ((avgLumChange > 0 && change > 0) || (avgLumChange < 0 && change < 0))
        }
        
        let consistentVarChanges = varChanges.filter { change in
            return ((avgVarChange > 0 && change > 0) || (avgVarChange < 0 && change < 0))
        }
        
        let lumConsistency = Float(consistentLumChanges.count) / Float(lumChanges.count)
        let varConsistency = Float(consistentVarChanges.count) / Float(varChanges.count)
        
        // Calculate correlation between luminance and variance changes
        let correlation = zip(lumChanges, varChanges).reduce(0) { sum, changes in
            let (lum, var_) = changes
            return sum + (lum * var_)
        } / Float(lumChanges.count)
        let correlationStrength = abs(correlation) / (abs(avgLumChange) * abs(avgVarChange))
        
        if abs(avgLumChange) >= FADE_THRESHOLD * 0.8 && lumConsistency >= FADE_CONSISTENCY_THRESHOLD {
            let fadeType: FadeAnalysis.FadeType = avgLumChange > 0 ? .fadeIn : .fadeOut
            
            // Calculate confidence incorporating variance behavior
            let magnitudeConfidence = min(abs(avgLumChange) / (FADE_THRESHOLD * 2), 1.0)
            let consistencyConfidence = (lumConsistency + varConsistency) / 2.0
            let correlationConfidence = min(correlationStrength, 1.0)
            
            // Final confidence calculation
            // Break down the weighted sum into steps
            let magnitudeComponent: Float = magnitudeConfidence * 0.3
            let consistencyComponent: Float = consistencyConfidence * 0.3
            let correlationComponent: Float = correlationConfidence * 0.2

            // Sum the components
            let baseConfidence = magnitudeComponent + consistencyComponent + correlationComponent

            // Apply the direction penalty
            let varianceDirectionPenalty: Float = sameDirection ? 1.0 : 0.5
            let confidence = baseConfidence * varianceDirectionPenalty
            
            return FadeAnalysis(
                type: fadeType,
                confidence: confidence,
                averageRate: abs(avgLumChange)
            )
        }
        
        if previousAnalysis?.type != FadeAnalysis.FadeType.none {
            let now = Date()
            print("\(formatter.string(from: now))--> None: avgLumChange \(abs(avgLumChange)) < \(FADE_THRESHOLD * 0.8) && lumConsistency \(lumConsistency) < \(FADE_CONSISTENCY_THRESHOLD)")
        }
        
        return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
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
 
    private func calculateSlope(for values: [Float]) -> Float {
        guard values.count >= 2 else { return 0.0 }
        
        let n = Float(values.count)
        // X values are just frame indices: [0, 1, 2, ..., n-1]
        let sumX = (n - 1.0) * n / 2.0  // Sum of arithmetic sequence
        let sumXX = (n - 1.0) * n * (2.0 * n - 1.0) / 6.0  // Sum of squares
        
        let sumY = values.reduce(0.0, +)
        let sumXY = zip(0..<values.count, values).map { Float($0) * $1 }.reduce(0.0, +)
        
        let denominator = n * sumXX - sumX * sumX
        if denominator.isZero { return 0.0 }
        
        return (n * sumXY - sumX * sumY) / denominator
    }

    private func updateStats(textureId: ObjectIdentifier, luminance: Float, variance: Float, edgeDensity: Float) {
        statsQueue.async {
            // Increment or initialize frame index for this texture
            if self.frameIndices[textureId] == nil {
                self.frameIndices[textureId] = 0
            }
            
            let currentIndex = self.frameIndices[textureId]!
            self.frameIndices[textureId] = currentIndex + 1
            
            let newStats = FrameStats(luminance: luminance,
                                    variance: variance,
                                    edgeDensity: edgeDensity,
                                    frameIndex: currentIndex)
            
            if self.frameStats[textureId] == nil {
                self.frameStats[textureId] = []
            }
            
            self.frameStats[textureId]?.append(newStats)
            
            // Keep only the last ROLLING_WINDOW frames
            if let count = self.frameStats[textureId]?.count,
               count > self.ROLLING_WINDOW {
                self.frameStats[textureId]?.removeFirst(count - self.ROLLING_WINDOW)
            }
        }
    }
    
    private func getStatsForTexture(_ textureId: ObjectIdentifier) -> (luminanceSlope: Float, varianceSlope: Float)? {
        var localStats: [FrameStats]?
        statsQueue.sync {
            localStats = frameStats[textureId]
        }
        
        guard let stats = localStats,
              stats.count >= 2 else {
            return nil
        }
        
        let luminances = stats.map { $0.luminance }
        let variances = stats.map { $0.variance }
        
        let lumSlope = calculateSlope(for: luminances)
        let varSlope = calculateSlope(for: variances)
        
        return (lumSlope, varSlope)
    }
    
    private func logFadeTransition(_ fadeAnalysis: FadeAnalysis, for textureId: ObjectIdentifier, luminance: Float, variance: Float, edgeDensity: Float) {
        let now = Date()
        print("""
        \(formatter.string(from: now)) \
        Frame: \(frameCount) / \(textureId) \
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
            return ["tex": texture, "alpha": Float(stream.alpha)]
        }
        
        // Process luminance calculations
        if !textures.isEmpty {
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
                updateStats(textureId: textureId, luminance: luminance, variance: variance, edgeDensity: edgeDensity)

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
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
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
                let textureId = texture["id"] as! ObjectIdentifier

                // Check for fade state changes
                let fadeAnalysis = analyzeFade(for: textureId)
                                
                // Fade state update and logging
                // Log only when fade state changes
                if let lastAnalysis = getLastFadeState(for: textureId) {
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
                updateLastFadeState(fadeAnalysis, for: textureId)

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
        renderEncoder.setFragmentBytes(bytes, length: length, index: 0)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: 6,
                                            indexType: .uint16,
                                            indexBuffer: indexBuffer,
                                            indexBufferOffset: 0)
     }
}
