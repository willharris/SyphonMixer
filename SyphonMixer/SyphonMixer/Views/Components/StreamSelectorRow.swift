//
//  StreamSelectorRow.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI

struct StreamSelectorRow: View {
    @Binding var stream: SyphonStream
    let availableServers: [String]
    let onAdd: () -> Void
    let onRemove: () -> Void
    let isLastStream: Bool
    
    // Helper computed property to ensure selection is always valid
    private var validServerName: String {
        if availableServers.contains(stream.serverName) {
            return stream.serverName
        }
        return ""
    }

    var body: some View {
        HStack {
            Picker("Stream", selection: Binding(
                get: { validServerName },
                set: { stream.serverName = $0 }
            )) {
                Text("None").tag("")
                ForEach(availableServers, id: \.self) { server in
                    Text(server).tag(server)
                }
            }
            .frame(width: 300)
            
            Toggle("Auto-fade", isOn: Binding(
                get: { stream.autoFade },
                set: { newValue in
                    stream.autoFade = newValue
                    if newValue {
                        stream.alpha = 0.0
                    }
                }
            ))
            .frame(width: 100)

            Text("Alpha")
            
            Slider(value: $stream.alpha, in: 0...1)
                .frame(width: 100)
            
            Picker("Scaling", selection: $stream.scalingMode) {
                ForEach(VideoScalingMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .frame(width: 200)
            
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(stream.serverName.isEmpty)
            
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .disabled(isLastStream)
        }
        .padding(.horizontal)
    }
}
