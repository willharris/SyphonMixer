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
    
    init(streams: Binding<[SyphonStream]>, device: MTLDevice) {
        self._streams = streams
        self._syphonManager = StateObject(wrappedValue: SyphonManager(device: device))
    }
    
    var body: some View {
        VStack {
            ForEach($streams) { $stream in
                StreamSelectorRow(
                    stream: $stream,
                    availableServers: syphonManager.availableServers,
                    onAdd: { streams.append(SyphonStream(serverName: "")) },
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
        .padding()
        .onChange(of: streams) { oldStreams, newStreams in
            // Update clients when stream selections change
            for (index, stream) in newStreams.enumerated() {
                if stream.serverName.isEmpty {
                    // Clear existing client if any
                    if let client = streams[index].client {
                        client.stop()
                        streams[index].client = nil
                    }
                } else if streams[index].client == nil {
                    // Create new client
                    streams[index].client = syphonManager.createClient(for: stream.serverName)
//                    streams[index].client?.start()
                }
            }
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
