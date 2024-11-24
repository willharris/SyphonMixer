//
//  ContentView.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI
import Metal

struct ContentView: View {
    @State private var isFullScreen = false
    
    let device: MTLDevice
    let manager: SyphonManager
    let commandQueue: MTLCommandQueue
    
    init(manager: SyphonManager) {
        self.manager = manager
        self.device = manager.device
        self.commandQueue = device.makeCommandQueue()!
    }
    
    var body: some View {
        MetalView(manager: manager, device: device, commandQueue: commandQueue)
            .ignoresSafeArea()
            .navigationTitle("Syphon Mixer")
        
    }
}

//#Preview {
//    ContentView()
//}
