//
//  SyphonStream.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import Foundation
import Syphon

struct SyphonStream: Identifiable, Equatable {
    let id = UUID()
    var serverName: String
    var client: SyphonMetalClient?
    var alpha: Double = 1.0
    var scalingMode: VideoScalingMode = .scaleToFill
    var autoFade: Bool = false
    
    static func == (lhs: SyphonStream, rhs: SyphonStream) -> Bool {
          return lhs.id == rhs.id && lhs.serverName == rhs.serverName
    }
}
