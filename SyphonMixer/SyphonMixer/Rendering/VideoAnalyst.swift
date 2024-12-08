//
//  VideoAnalyst.swift
//  SyphonMixer
//
//  Created by William Harris on 27.11.2024.
//
import Metal

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

class VideoAnalyst {
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

    // Thread-safe accessors for state
    func getFrameStats(for textureId: ObjectIdentifier) -> [FrameStats]? {
        var result: [FrameStats]?
        statsQueue.sync {
            result = frameStats[textureId]
        }
        return result
    }

    func getCurrentFrameIndex(for textureId: ObjectIdentifier) -> Int {
        var result: Int = 0
        statsQueue.sync {
            result = frameIndices[textureId] ?? 0
        }
        return result
    }

    func updateLastFadeState(_ analysis: FadeAnalysis, for textureId: ObjectIdentifier) {
        fadeStateQueue.async {
            self.lastFadeState[textureId] = analysis
        }
    }

    func getLastFadeState(for textureId: ObjectIdentifier) -> FadeAnalysis? {
        var result: FadeAnalysis?
        fadeStateQueue.sync {
            result = lastFadeState[textureId]
        }
        return result
    }
    
    func updateStats(textureId: ObjectIdentifier, luminance: Float, variance: Float, edgeDensity: Float) {
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
    

    func analyzeFade(for textureId: ObjectIdentifier, frameCount: Int) -> FadeAnalysis {
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
        
        // Calculate total changes
        let totalLumChange = abs(luminances.last! - luminances.first!)
        let totalVarChange = abs(variances.last! - variances.first!)
        
        let previousAnalysis = getLastFadeState(for: textureId)
        
        // Detect near-black state (both luminance and variance near zero)
        let isNearBlack = luminances.last! < 0.02 && variances.last! < 0.001  // 2% brightness, 0.1% variance
        let wasNearBlack = luminances.first! < 0.02 && variances.first! < 0.001
        
        // Enhanced direction check considering final values
        let isTowardsBlack = luminances.last! < 0.2 // 20% brightness
        let isFromBlack = luminances.first! < 0.2
        
        // Enhanced early exit with stricter thresholds
        let lumThreshold = FADE_THRESHOLD * Float(MIN_FADE_FRAMES) * 0.5
        let varThreshold = lumThreshold * 0.3
        
        // Special case for transitions to/from near-black
        if isNearBlack || wasNearBlack {
            let fadeType: FadeAnalysis.FadeType = isNearBlack ? .fadeOut : .fadeIn
            let rate = totalLumChange / Float(stats.count)
            
            if rate >= FADE_THRESHOLD * 0.5 {
                return FadeAnalysis(
                    type: fadeType,
                    confidence: 1.0,  // Maximum confidence for true black transitions
                    averageRate: rate
                )
            }
        }
        
        if totalLumChange < lumThreshold || totalVarChange < varThreshold {
            if previousAnalysis?.type != FadeAnalysis.FadeType.none {
                let now = Date()
                print("\(formatter.string(from: now)) Frame: \(frameCount) --> None: totalLumChange \(totalLumChange) < \(lumThreshold) or totalVarChange \(totalVarChange) < \(varThreshold)")
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
        
        // Prevent rapid re-triggering of fades
        if previousAnalysis?.type != FadeAnalysis.FadeType.none {
            // If we just detected a fade, require a significant stable period before detecting another
            let isStable = abs(avgLumChange) < FADE_THRESHOLD * 0.5
            if !isStable {
                return previousAnalysis!
            }
        }
        
        let hasSignificantVarChange = totalVarChange >= varThreshold * 2
        
        // Calculate consistency with stricter thresholds
        let consistentLumChanges = lumChanges.filter { change in
            return abs(change) >= FADE_THRESHOLD * 0.8 &&
                   ((avgLumChange > 0 && change > 0) || (avgLumChange < 0 && change < 0))
        }
        
        let consistentVarChanges = varChanges.filter { change in
            return abs(change) >= FADE_THRESHOLD * 0.2 &&
                   ((avgVarChange > 0 && change > 0) || (avgVarChange < 0 && change < 0))
        }
        
        let lumConsistency = Float(consistentLumChanges.count) / Float(lumChanges.count)
        let varConsistency = Float(consistentVarChanges.count) / Float(varChanges.count)
        
        // Calculate correlation with more weight on consistent changes
        let correlation = zip(lumChanges, varChanges).reduce(0) { sum, changes in
            let (lum, var_) = changes
            return sum + (lum * var_)
        } / Float(lumChanges.count)
        let correlationStrength = abs(correlation) / (abs(avgLumChange) * abs(avgVarChange))
        
        // Enhanced fade detection with stricter criteria
        if abs(avgLumChange) >= FADE_THRESHOLD * 0.8 &&
           lumConsistency >= FADE_CONSISTENCY_THRESHOLD &&
           hasSignificantVarChange {
            
            let fadeType: FadeAnalysis.FadeType
            var endingConfidenceBoost: Float = 0
            
            if avgLumChange > 0 {
                fadeType = .fadeIn
                endingConfidenceBoost = isFromBlack ? 0.4 : 0
            } else {
                fadeType = .fadeOut
                endingConfidenceBoost = isTowardsBlack ? 0.4 : 0
                // Extra boost for fades heading towards very dark
                if luminances.last! < 0.1 { // < 10% brightness
                    endingConfidenceBoost += 0.2
                }
            }
            
            // Enhanced confidence calculation with more weight on consistency
            let magnitudeConfidence = min((abs(avgLumChange) + abs(avgVarChange) * 0.5) / (FADE_THRESHOLD * 2.5), 1.0)
            let consistencyConfidence = (lumConsistency * 0.7 + varConsistency * 0.3)  // More weight on luminance consistency
            let correlationConfidence = min(correlationStrength, 1.0)
            
            // Weighted confidence calculation
            let magnitudeComponent = magnitudeConfidence * 0.35
            let consistencyComponent = consistencyConfidence * 0.45  // Increased weight
            let correlationComponent = correlationConfidence * 0.2
            
            var baseConfidence = magnitudeComponent + consistencyComponent + correlationComponent
            
            // Apply boost for true fades
            baseConfidence += endingConfidenceBoost
            
            // Cap confidence at 100%
            baseConfidence = min(baseConfidence, 1.0)
            
            // Reject low confidence fades more aggressively
            if baseConfidence < 0.45 {  // Increased threshold
                return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
            }
            
            return FadeAnalysis(
                type: fadeType,
                confidence: baseConfidence,
                averageRate: abs(avgLumChange)
            )
        }
        
        if previousAnalysis?.type != FadeAnalysis.FadeType.none {
            let now = Date()
            print("\(formatter.string(from: now)) Frame: \(frameCount) --> None: avgLumChange \(abs(avgLumChange)) < \(FADE_THRESHOLD * 0.8) or hasSignificantVarChange \(hasSignificantVarChange)")
        }
        
        return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
    }}
