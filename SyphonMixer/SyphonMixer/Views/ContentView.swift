//
//  ContentView.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI
import Metal

struct ContentView: View {
    @Binding var streams: [SyphonStream]
    @State private var isFullScreen = false
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    init(streams: Binding<[SyphonStream]>, device: MTLDevice) {
        self._streams = streams
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
    }
    
    var body: some View {
        MetalView(streams: streams, device: device, commandQueue: commandQueue)
            .ignoresSafeArea()
    }
}

//#Preview {
//    ContentView()
//}
