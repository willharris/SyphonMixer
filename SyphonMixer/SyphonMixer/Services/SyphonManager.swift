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
            selector: #selector(handleServersDidChange),
            name: NSNotification.Name.SyphonServerRetire,
            object: nil
        )
        
        // Initial server discovery
        discoverServers()
    }
    
    @objc private func handleServersDidChange(_ notification: Notification) {
        discoverServers()
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
        return client
    }
    
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
    }
    
    deinit {
        cleanup()
    }
}
