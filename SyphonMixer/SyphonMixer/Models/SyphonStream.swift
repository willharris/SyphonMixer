//
//  SyphonStream.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import Foundation
import Syphon

class SyphonStream: Identifiable, Equatable, ObservableObject {
    var onServerNameChange: ((String) -> Void)?
    var onAutoFadeChange: ((Bool) -> Void)?
    var onDisplayAlphaChange: ((Double) -> Void)?

    let id = UUID()
    @Published var serverName: String {
        didSet {
            onServerNameChange?(serverName)
        }
    }
    @Published var client: SyphonMetalClient?
    @Published var alpha: Double
    @Published var displayAlpha: Double {
        didSet {
            onDisplayAlphaChange?(displayAlpha)
        }
    }
    @Published var scalingMode: VideoScalingMode
    @Published var autoFade: Bool {
        didSet {
            onAutoFadeChange?(autoFade)
        }
    }
        
    init(serverName: String = "",
         autoFade: Bool = false,
         alpha: Double = 1.0,
         scalingMode: VideoScalingMode = .scaleToFill) {
        self.serverName = serverName
        self.autoFade = autoFade
        self.alpha = alpha
        self.displayAlpha = alpha
        self.scalingMode = scalingMode
    }

    static func == (lhs: SyphonStream, rhs: SyphonStream) -> Bool {
          return lhs.id == rhs.id && lhs.serverName == rhs.serverName
    }
}
