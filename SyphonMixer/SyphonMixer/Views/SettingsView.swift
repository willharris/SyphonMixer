//
//  SettingsView.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import SwiftUI
import Metal
import Combine


private class SettingsViewModel: ObservableObject {
    @Published var cancellables = Set<AnyCancellable>()
}

struct SettingsView: View {
    @ObservedObject private var syphonManager: SyphonManager
    @StateObject private var model = SettingsViewModel()

    init(manager: SyphonManager) {
        self.syphonManager = manager
    }
    
    private func createRowModel(_ stream: SyphonStream) -> StreamSelectorRowModel {
        return StreamSelectorRowModel(
            stream: stream,
            syphonManager: syphonManager
        )
    }

    var body: some View {
        VStack {
            ForEach(syphonManager.streams) { stream in
                StreamSelectorRowView(
                    model: createRowModel(stream)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
