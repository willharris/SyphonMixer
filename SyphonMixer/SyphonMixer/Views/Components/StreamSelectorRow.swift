//
//  StreamSelectorRow.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import Combine
import SwiftUI


class StreamSelectorRowModel: ObservableObject {
    @Published var stream: SyphonStream
    @ObservedObject var manager: SyphonManager
    
    private var cancellables = Set<AnyCancellable>()
    
    init(stream: SyphonStream,
         syphonManager: SyphonManager) {
        self.stream = stream
        self.manager = syphonManager
        
        stream.onServerNameChange = { [weak self] _ in
            guard let self = self else { return }
            self.manager.createClient(for: self.stream)
        }
        
        stream.onAutoFadeChange = { [weak self] enabled in
            if enabled {
                self?.stream.alpha = 0.0
            }
        }

    }
        
    func isLastStream() -> Bool {
        return manager.streams.count == 1
    }
    
    func onAdd() {
        manager.addStream(SyphonStream())
        print("Added, num streams: \(manager.streams.count)")
    }
    
    func onRemove() {
        if manager.streams.count > 1,
           let index = manager.streams.firstIndex(where: { $0.id == stream.id })
        {
            manager.removeStream(at: index)
        }
        print("Removed, num streams: \(manager.streams.count)")
    }
}

struct StreamSelectorRowView: View {
    @StateObject var model: StreamSelectorRowModel

    // Helper computed property to ensure selection is always valid
    private var validServerName: String {
        if model.manager.availableServers.contains(model.stream.serverName) {
            return model.stream.serverName
        }
        return ""
    }

    var body: some View {
        HStack {
            Picker("Stream", selection: $model.stream.serverName) {
                Text("None").tag("")
                ForEach(model.manager.availableServers, id: \.self) { server in
                    Text(server).tag(server)
                }
            }
            .frame(width: 300)
            
            Toggle("Auto-fade", isOn: $model.stream.autoFade)
            .frame(width: 100)

            Text("Alpha")
            
            Slider(value: Binding(
                get: { model.stream.alpha },
                set: { newValue in
                    if (!model.stream.autoFade) {
                        model.stream.alpha = newValue
                        model.objectWillChange.send()
                    }
                }
            ), in: 0...1)
            .disabled(model.stream.autoFade)
            .frame(width: 100)

            Picker("Scaling", selection: $model.stream.scalingMode) {
                ForEach(VideoScalingMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 200)
            
            Button(action: model.onAdd) {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(model.stream.serverName.isEmpty)
            
            Button(action: model.onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .disabled(model.isLastStream())
        }
        .padding(.horizontal)
    }
}
