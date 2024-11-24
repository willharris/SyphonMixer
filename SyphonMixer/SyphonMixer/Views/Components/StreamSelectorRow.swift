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
    
    var body: some View {
        HStack {
            Picker("Server", selection: $stream.serverName) {
                Text("None").tag("")
                ForEach(availableServers, id: \.self) { server in
                    Text(server).tag(server)
                }
            }
            .frame(width: 200)
            
            Slider(value: $stream.alpha, in: 0...1)
                .frame(width: 100)
            
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
            }
            
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
        }
        .padding(.horizontal)
    }
}
