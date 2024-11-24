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
        Window("Syphon Mixer", id: "main") {
            ContentView(
                manager: syphonManager
            )
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
                
        Settings {
            SettingsView(
                streams: Binding(
                    get: { self.syphonManager.streams },
                    set: { self.syphonManager.streams = $0 }
                )
            )
            .frame(width: 400, height: 400)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            // Hack to prevent the settings window from interfering with main window full-screen shortcut
            CommandGroup(replacing: .windowSize) { }
        }
        

    }
}
