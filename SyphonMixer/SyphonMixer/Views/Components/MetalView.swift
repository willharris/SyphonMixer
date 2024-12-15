//
//  MetalView.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import os

import Combine
import SwiftUI
import MetalKit

// The coordinator that handles subscriptions and Metal work
class MetalViewCoordinator: NSObject, MTKViewDelegate {
    var parent: MetalView
    var streams: [SyphonStream]
    private var renderer: SyphonRenderer!
    private var cancellables: Set<AnyCancellable> = []
    
    init(_ parent: MetalView) {
        self.parent = parent
        self.streams = parent.manager.streams
        super.init()
        setupEventHandling()
    }
    
    private func setupEventHandling() {
        StreamConfigurationEvents.shared.publisher
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .alphaChanged(let stream):
                    self.renderer.handleStreamAlphaChange(stream: stream)
                case .autoFadeToggled(let stream):
                    self.renderer.handleStreamConfigurationChange(stream: stream)
                }
            }
            .store(in: &self.cancellables)
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if renderer == nil {
            renderer = SyphonRenderer(device: parent.device)
        }
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }
        let commandQueue = parent.commandQueue
        
        let renderCommandBuffer = renderer.render(streams: streams,
                               in: view,
                               commandQueue: commandQueue,
                               renderPassDescriptor: renderPassDescriptor)
        renderCommandBuffer.present(drawable)
        renderCommandBuffer.commit()
    }
}

// The view struct that implements NSViewRepresentable
struct MetalView: NSViewRepresentable {
    @ObservedObject var manager: SyphonManager
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.delegate = context.coordinator
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.streams = manager.streams
    }
    
    func makeCoordinator() -> MetalViewCoordinator {
        MetalViewCoordinator(self)
    }
}
