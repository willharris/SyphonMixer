//
//  SyphonMixerApp.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI


@main
struct SyphonMixerApp: App {
    @StateObject private var syphonManager = SyphonManager()

    var body: some Scene {
        WindowGroup("Syphon Mixer") {
            ContentView(
                manager: syphonManager
            )
        }
        
        Settings {
            SettingsView(
                streams: Binding(
                    get: { self.syphonManager.streams },
                    set: { self.syphonManager.streams = $0 }
                )
            )
            .frame(width: 400, height: 400)
        }

    }
}
