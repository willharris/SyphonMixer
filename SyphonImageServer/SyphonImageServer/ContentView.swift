//
//  ContentView.swift
//  SyphonImageServer
//
//  Created by William Harris on 17.11.2024.
//

import SwiftUI

import SwiftUI

struct ContentView: View {
    @StateObject private var syphonServer = SyphonImageServer()
    @State private var selectedImage: NSImage?
    
    var body: some View {
        VStack(spacing: 20) {
            if let image = selectedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
            } else {
                Text("No image selected")
                    .frame(height: 300)
            }
            
            Button("Choose Image") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.image]
                
                if panel.runModal() == .OK {
                    if let url = panel.url {
                        if let image = NSImage(contentsOf: url) {
                            selectedImage = image
                            syphonServer.publishImage(image)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
