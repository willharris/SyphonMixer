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
    @State private var isFloating = false
    @State private var isFullScreen = false

    init() {
        // Disable the full screen menu item because it disappears anyway as soon as you
        // interact with any widget in the settings window
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
    }
    
    var body: some Scene {
        Window("Syphon Mixer", id: "main") {
            ContentView(
                manager: syphonManager
            )
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(WindowResizability.contentMinSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Float Window", isOn: Binding(
                    get: { isFloating },
                    set: { newValue in
                        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                            window.level = newValue ? .floating : .normal
                            isFloating = newValue
                        }
                    }
                ))
                .keyboardShortcut("f", modifiers: [.command, .option])

                Toggle("Full Screen", isOn: Binding(
                    get: { isFullScreen },
                    set: { newValue in
                        isFullScreen = newValue
                        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                            window.toggleFullScreen(newValue)
                            window.makeKeyAndOrderFront(nil)  // Brings window to front and gives it focus
                            NSApplication.shared.activate(ignoringOtherApps: true)  // Make frontmost
                        }
                    }
                ))
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
            
        }

        Settings {
            SettingsView(
                streams: Binding(
                    get: { self.syphonManager.streams },
                    set: { self.syphonManager.streams = $0 }
                ),
                manager: self.syphonManager
            )
            .frame(minWidth: 750)
        }
        .windowStyle(.titleBar)
//        .windowStyle(.titleBar)
//        .windowResizability(.contentSize)
    }
}
