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

    var body: some View {
        HStack {
            Picker("Stream", selection: $stream.serverName) {
                Text("None").tag("")
                ForEach(availableServers, id: \.self) { server in
                    Text(server).tag(server)
                }
            }
            .frame(width: 200)
            
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
