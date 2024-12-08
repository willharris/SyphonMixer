//
//  SettingsView.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI
import Metal

struct SettingsView: View {
    @Binding var streams: [SyphonStream]
    @StateObject private var syphonManager: SyphonManager
    
    init(streams: Binding<[SyphonStream]>) {
        self._streams = streams
        self._syphonManager = StateObject(wrappedValue: SyphonManager())
    }
    
    var body: some View {
        VStack {
            ForEach($streams) { $stream in
                StreamSelectorRow(
                    stream: $stream,
                    availableServers: syphonManager.availableServers,
                    onAdd: {
                        streams.append(SyphonStream(serverName: ""))
                    },
                    onRemove: {
                        if let index = streams.firstIndex(where: { $0.id == stream.id }) {
                            // Cleanup existing client if any
                            if let client = streams[index].client {
                                client.stop()
                            }
                            streams.remove(at: index)
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .onChange(of: streams) { oldStreams, newStreams in
            // Create a local copy to avoid modifying while iterating
            var updatedStreams = newStreams
                        
            for index in updatedStreams.indices {
                let stream = updatedStreams[index]
                            
                if stream.serverName.isEmpty {
                    // Clear existing client if any
                    if let client = stream.client {
                        client.stop()
                        updatedStreams[index].client = nil
                    }
                } else {
                    // Check if we need to create or update the client
                    let oldStream = oldStreams.first { $0.id == stream.id }
                                
                    if oldStream?.serverName != stream.serverName {
                        // Server name changed, stop old client if it exists
                        if let client = stream.client {
                            client.stop()
                        }
                        // Create new client
                        updatedStreams[index].client = syphonManager
                            .createClient(for: stream.serverName)
                    }
                }
            }
                        
            // Update the streams binding with our modified version
            streams = updatedStreams
        }
        .onDisappear {
            // Cleanup when view disappears
            for stream in streams {
                stream.client?.stop()
            }
            syphonManager.cleanup()
        }
    }
}
