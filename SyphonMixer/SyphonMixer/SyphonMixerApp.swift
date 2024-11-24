//
//  SyphonMixerApp.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI

// First, create a state object to hold our shared state
class AppState: ObservableObject {
    @Published var streams: [SyphonStream] = [SyphonStream(serverName: "")]
}

class SettingsWindowController {
    private var settingsWindow: NSWindow?
    let device: MTLDevice
    let appState: AppState
    
    init(device: MTLDevice, appState: AppState) {
        self.device = device
        self.appState = appState
    }
    
    func showWindow() {
        if settingsWindow == nil {
            // Create the window if it doesn't exist
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            
            window.title = "Settings"
            window.contentView = NSHostingView(
                rootView: SettingsView(
                    streams: Binding(
                        get: { self.appState.streams },
                        set: { self.appState.streams = $0 }
                    ),
                    device: device
                )
            )
            window.center()
            window.setFrameAutosaveName("Settings Window")
            
            settingsWindow = window
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SyphonMixerApp: App {
    @StateObject private var appState = AppState()
    private let settingsWindowController: SettingsWindowController
    let device: MTLDevice
    
    init() {
        self.device = MTLCreateSystemDefaultDevice()!
        
        // Create a temporary AppState for the controller
        // We can't access the @StateObject directly during initialization
        let tempAppState = AppState()
        self.settingsWindowController = SettingsWindowController(
            device: device,
            appState: tempAppState
        )
        
        // Make sure the StateObject uses the same AppState
        self._appState = StateObject(wrappedValue: tempAppState)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                streams: Binding(
                    get: { self.appState.streams },
                    set: { self.appState.streams = $0 }
                ),
                device: device
            )
        }
        .commands {
            CommandGroup(after: .windowSize) {
                Button("Settings...") {
                    settingsWindowController.showWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            CommandMenu("View") {
                Button("Show Settings") {
                    settingsWindowController.showWindow()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}
