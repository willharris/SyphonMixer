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
    let timestamp: TimeInterval
}

struct BlackFrameState {
    var isBlack: Bool = false
    var blackFrameStartTime: TimeInterval = 0
    var consecutiveBlackFrames: Int = 0
}

struct FadeAnalysis {
    enum FadeType {
        case none
        case fadeIn
        case potentialFadeOut
        case fadeOut
        
        var description: String {
            switch self {
            case .none: return "No fade"
            case .fadeIn: return "Fade IN"
            case .potentialFadeOut: return "Potential Fade OUT"
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
    private let FADE_THRESHOLD: Float = 0.0008  // Detect 0.08% changes per frame
    private let FADE_CONSISTENCY_THRESHOLD: Float = 0.40  // Consistency threshold for fade detection
    private let MIN_FADE_FRAMES = 30  // Minimum number of frames to analyze
    private let fadeStateQueue = DispatchQueue(label: "com.syphonmixer.fadestate")
    
    // Black frame detection parameters
    private let BLACK_LUMINANCE_THRESHOLD: Float = 0.01  // 1% maximum brightness for black
    private let BLACK_VARIANCE_THRESHOLD: Float = 0.001  // 0.1% maximum variance for black
    private let REQUIRED_BLACK_DURATION: TimeInterval = 0.5  // Configurable duration in seconds
    private var blackFrameStates: [ObjectIdentifier: BlackFrameState] = [:]
    
    // Track previous fade state per texture
    private var lastFadeState: [ObjectIdentifier: FadeAnalysis] = [:]

    init() {
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    
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
                                      frameIndex: currentIndex,
                                      timestamp: Date().timeIntervalSince1970)
            
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
    
    private func updateBlackFrameState(textureId: ObjectIdentifier, stats: FrameStats) -> Bool {
        var state = blackFrameStates[textureId] ?? BlackFrameState()
        let currentTime = stats.timestamp
        
        let isBlackFrame = stats.luminance < BLACK_LUMINANCE_THRESHOLD && stats.variance < BLACK_VARIANCE_THRESHOLD
        
        if isBlackFrame {
            if !state.isBlack {
                // First black frame
                state.isBlack = true
                state.blackFrameStartTime = currentTime
                state.consecutiveBlackFrames = 1
            } else {
                state.consecutiveBlackFrames += 1
            }
        } else {
            state.isBlack = false
            state.consecutiveBlackFrames = 0
        }
        
        blackFrameStates[textureId] = state
        
        // Check if we've had black frames for the required duration
        if state.isBlack {
            let blackDuration = currentTime - state.blackFrameStartTime
            return blackDuration >= REQUIRED_BLACK_DURATION
        }
        
        return false
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
        
        // First, check if we have enough black frames at any point - this overrides everything else
        guard let latestStats = stats.last else {
            return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
        }
        
        if updateBlackFrameState(textureId: textureId, stats: latestStats) {
            return FadeAnalysis(type: .fadeOut, confidence: 1.0, averageRate: 0)
        }
        
        let luminances = stats.map { $0.luminance }
        let variances = stats.map { $0.variance }
        
        // Calculate frame-to-frame changes
        var lumChanges: [Float] = []
        for i in 1..<stats.count {
            lumChanges.append(luminances[i] - luminances[i-1])
        }
        
        let avgLumChange = lumChanges.reduce(0, +) / Float(lumChanges.count)
        let previousAnalysis = getLastFadeState(for: textureId)
        
        // Phase 2: If we're already in a potential fade out, just check if it's still getting darker
        if previousAnalysis?.type == .potentialFadeOut {
            // Check if we're getting brighter (fade out interrupted)
            let recentLumChange = luminances.last! - luminances.dropLast().last!
            if recentLumChange > FADE_THRESHOLD * 0.5 {
                let now = Date()
                print("\(formatter.string(from: now)) Frame: \(frameCount) --> Potential fade out interrupted: brightness increasing: \(recentLumChange) > \(FADE_THRESHOLD * 0.5)")
                return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
            }
            
            // Continue tracking the fade out
            return FadeAnalysis(
                type: .potentialFadeOut,
                confidence: previousAnalysis!.confidence,
                averageRate: abs(avgLumChange)
            )
        }
        
        // Phase 1: Initial detection using confidence calculation
        // Calculate total changes
        let totalLumChange = abs(luminances.last! - luminances.first!)
        let totalVarChange = abs(variances.last! - variances.first!)
        
        // Enhanced early exit with stricter thresholds
        let lumThreshold = FADE_THRESHOLD * Float(MIN_FADE_FRAMES) * 0.5
        let varThreshold = lumThreshold * 0.3
        
        if totalLumChange < lumThreshold || totalVarChange < varThreshold {
            return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
        }
        
        let hasSignificantVarChange = totalVarChange >= varThreshold * 2
        
        // Calculate consistency
        let consistentLumChanges = lumChanges.filter { change in
            return abs(change) >= FADE_THRESHOLD * 0.8 &&
                   ((avgLumChange > 0 && change > 0) || (avgLumChange < 0 && change < 0))
        }
        
        let lumConsistency = Float(consistentLumChanges.count) / Float(lumChanges.count)
        
        // Enhanced fade detection with stricter criteria
        if abs(avgLumChange) >= FADE_THRESHOLD * 0.8 &&
           lumConsistency >= FADE_CONSISTENCY_THRESHOLD &&
           hasSignificantVarChange {
            
            let fadeType: FadeAnalysis.FadeType = avgLumChange > 0 ? .fadeIn : .fadeOut
            
            let confidence = calculateFadeConfidence(
                lumChange: avgLumChange,
                varChange: totalVarChange,
                consistency: lumConsistency,
                currentLuminance: luminances.last!,
                targetLuminance: fadeType == .fadeIn ? luminances.last! : luminances.first!
            )
            
            // Only proceed if confidence meets minimum threshold
            if confidence >= 0.6 {
                if fadeType == .fadeOut {
                    let now = Date()
                    print("\(formatter.string(from: now)) Frame: \(frameCount) --> Potential fade out detected with confidence \(confidence)")
                    return FadeAnalysis(type: .potentialFadeOut, confidence: confidence, averageRate: abs(avgLumChange))
                } else {
                    return FadeAnalysis(type: .fadeIn, confidence: confidence, averageRate: abs(avgLumChange))
                }
            }
        }
        
        return FadeAnalysis(type: .none, confidence: 0, averageRate: 0)
    }

    private func calculateFadeConfidence(
            lumChange: Float,
            varChange: Float,
            consistency: Float,
            currentLuminance: Float,
            targetLuminance: Float
        ) -> Float {
            // Magnitude confidence based on luminance and variance changes
            let magnitudeConfidence = min((abs(lumChange) + abs(varChange) * 0.5) / (FADE_THRESHOLD * 2.0), 1.0)
            
            // Direction confidence - how well does the change match expected fade behavior
            let directionConfidence: Float
            if lumChange > 0 {  // Fade in
                // For fade in, we want to see movement away from darkness
                directionConfidence = targetLuminance > 0.15 ? 1.0 : 0.5  // Boost if we're heading to significant brightness
            } else {  // Fade out
                // For fade out, we want to see movement toward near-black
                directionConfidence = targetLuminance < 0.05 ? 1.0 : 0.5  // Boost if we're heading to near-black
            }
            
            // Rate confidence - changes should be smooth but significant
            let rateConfidence = min(abs(lumChange) / (FADE_THRESHOLD * 0.5), 1.0)
            
            // Calculate weighted components
            let weights: [Float] = [0.35, 0.35, 0.15, 0.15]  // Must sum to 1.0
            let components: [Float] = [
                magnitudeConfidence,
                consistency,
                directionConfidence,
                rateConfidence
            ]
            
            var confidence: Float = 0
            for (weight, component) in zip(weights, components) {
                confidence += weight * component
            }
            
            // Add situational boosts
            if lumChange < 0 {  // Fade out
                if currentLuminance < 0.05 && abs(lumChange) >= FADE_THRESHOLD {
                    // Boost confidence if we're already very dark and still changing
                    confidence += 0.1
                }
            } else {  // Fade in
                if currentLuminance > 0.2 && abs(lumChange) >= FADE_THRESHOLD {
                    // Boost confidence if we're reaching good brightness and still changing
                    confidence += 0.1
                }
            }
            
            // Final normalization
            return min(confidence, 1.0)
        }}
