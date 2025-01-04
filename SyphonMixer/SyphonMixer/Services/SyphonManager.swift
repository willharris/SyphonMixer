//
//  SyphonManager.swift
//  SyphonMixer
//
//  Created by William Harris on 19.11.2024.
//

import Foundation
import Syphon
import Metal

class SyphonManager: ObservableObject {
    @Published var availableServers: [String] = []
    @Published var streams: [SyphonStream] = []
    let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private var serverBrowser: SyphonServerDirectory?
    
    // Dictionary to keep track of active clients and their server descriptions
    private var activeClients: [String: SyphonMetalClient] = [:]
    
    init() {
        setupServerBrowser()
        streams.append(SyphonStream(serverName: ""))
    }
    
    private func setupServerBrowser() {
        serverBrowser = SyphonServerDirectory.shared()
        
        // Register for server updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServersDidChange),
            name: NSNotification.Name.SyphonServerAnnounce,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServerRetirement),
            name: NSNotification.Name.SyphonServerRetire,
            object: nil
        )
        
        // Initial server discovery
        discoverServers()
    }
    
    @objc private func handleServersDidChange(_ notification: Notification) {
        discoverServers()
    }
    
    @objc private func handleServerRetirement(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let name = userInfo[SyphonServerDescriptionNameKey] as? String,
              let appName = userInfo[SyphonServerDescriptionAppNameKey] as? String else {
            return
        }
        
        let serverDescription = "\(appName): \(name)"
        
        // Cleanup the retired client
        if let client = activeClients[serverDescription] {
            client.stop()
            activeClients.removeValue(forKey: serverDescription)
        }
        
        // Update streams that were using this server
        for (index, stream) in streams.enumerated() {
            if stream.serverName == serverDescription {
                // Reset the stream to empty state
                DispatchQueue.main.async {
                    self.streams[index] = SyphonStream()
                }
            }
        }
        
        // Update available servers list
        discoverServers()
    }

    func addStream(_ stream: SyphonStream) {
        streams.append(stream)
    }
    
    func removeStream(at index: Int) {
        streams.remove(at: index)
    }
    
    func updateStreams(_ newStreams: [SyphonStream]) {
        streams = newStreams
    }
    
    func discoverServers() {
        guard let servers = serverBrowser?.servers(matchingName: nil, appName: nil) as? [[String: Any]] else {
            availableServers = []
            return
        }
        
        availableServers = servers.compactMap { serverInfo in
            guard let name = serverInfo[SyphonServerDescriptionNameKey] as? String,
                  let appName = serverInfo[SyphonServerDescriptionAppNameKey] as? String else {
                return nil
            }
            return "\(appName): \(name)"
        }
    }
    
    func createClient(for stream: SyphonStream) {
        if let oldClient = stream.client {
            oldClient.stop()
            stream.client = nil
        }
        if !stream.serverName.isEmpty {
            let newClient = createClient(for: stream.serverName)
            if newClient != nil {
                stream.client = newClient
            }
        }
    }
    
    func createClient(for serverDescription: String) -> SyphonMetalClient? {
        guard let servers = serverBrowser?.servers(matchingName: nil, appName: nil) as? [[String: Any]] else {
            return nil
        }
        
        // Find matching server info
        let serverInfo = servers.first { serverInfo in
            guard let name = serverInfo[SyphonServerDescriptionNameKey] as? String,
                  let appName = serverInfo[SyphonServerDescriptionAppNameKey] as? String else {
                return false
            }
            return "\(appName): \(name)" == serverDescription
        }
        
        guard let serverInfo else {
            return nil
        }
        
        // Create Syphon client
        let client = SyphonMetalClient(serverDescription: serverInfo, device: device, options: nil)
        
        // Store the client in our active clients dictionary
        activeClients[serverDescription] = client
        
        return client
    }
    
    func cleanup() {
        // Stop and cleanup all active clients
        for client in activeClients.values {
            client.stop()
        }
        activeClients.removeAll()
        
        NotificationCenter.default.removeObserver(self)
    }
    
    deinit {
        cleanup()
    }
}
