//
//  MetalView.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI
import MetalKit

struct MetalView: NSViewRepresentable {
    var streams: [SyphonStream]
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var renderer: SyphonRenderer!

    public init(streams: [SyphonStream], device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.streams = streams
        self.device = device
        self.commandQueue = commandQueue
    }
    
    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.delegate = context.coordinator
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.colorPixelFormat = .bgra8Unorm
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.streams = streams
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalView
        var streams: [SyphonStream]
        
        init(_ parent: MetalView) {
            self.parent = parent
            self.streams = parent.streams
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            if parent.renderer == nil {
                parent.renderer = SyphonRenderer(device: parent.device)
            }
        }
        
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = parent.commandQueue.makeCommandBuffer(),
                  let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
            
            parent.renderer.render(streams: streams,
                           in: view,
                           commandBuffer: commandBuffer,
                           renderPassDescriptor: renderPassDescriptor)
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
