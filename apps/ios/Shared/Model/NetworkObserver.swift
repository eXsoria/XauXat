//
//  NetworkObserver.swift
//  SimpleX (iOS)
//
//  Created by Avently on 05.04.2024.
//  Copyright © 2024 SimpleX Chat. All rights reserved.
//

import Foundation
import Network
import SimpleXChat

class NetworkObserver {
    static let shared = NetworkObserver()
    private let queue = DispatchQueue(label: "pt.exsoria.xauxat.NetworkObserver")
    // All monitor state is owned by queue. Old monitor callbacks are ignored.
    private var prevInfo: UserNetworkInfo?
    private var prevPath: NWPath?
    private var monitor: NWPathMonitor?
    private var monitorGeneration = UUID()

    func startMonitor() {
        queue.async { [self] in
            guard monitor == nil else { return }
            let generation = UUID()
            monitorGeneration = generation
            prevInfo = nil
            prevPath = nil
            let mon = NWPathMonitor()
            mon.pathUpdateHandler = { [weak self] path in
                guard let self, self.monitorGeneration == generation else { return }
                self.networkPathChanged(path: path)
            }
            monitor = mon
            mon.start(queue: queue)
        }
    }

    /// Monitoring starts before Tor/database initialization. A newly opened
    /// core still needs the cached availability, without manufacturing another
    /// path change and interrupting the route that just finished bootstrapping.
    func updateCoreNetworkInfo() {
        startMonitor()
        queue.async { [self] in
            guard let info = prevInfo, hasChatCtrl() else { return }
            do { try apiSetNetworkInfo(info) }
            catch { logger.error("XauXat could not update core network availability") }
        }
    }

    private func networkPathChanged(path: NWPath) {
        let info = UserNetworkInfo(
            networkType: networkTypeFromPath(path),
            online: path.status == .satisfied
        )
        let infoChanged = prevInfo != info
        let pathChanged = prevPath != path
        prevInfo = info
        prevPath = path
        // Compare the complete path, not only Wi-Fi/cellular availability: a
        // real change on the same interface still invalidates old connections.
        // Repeated equal snapshots must not cancel a working recovery attempt.
        DispatchQueue.main.async {
            ChatModel.shared.networkInfo = info
            let network: XauXatConnectionRecoveryManager.Network
            switch info.networkType {
            case .wifi: network = .wifi
            case .cellular: network = .cellular
            case .ethernet: network = .ethernet
            default: network = .other
            }
            if pathChanged {
                XauXatConnectionRecoveryManager.shared.networkChanged(online: info.online, network: network)
            } else {
                XauXatConnectionRecoveryManager.shared.networkUnchanged()
            }
        }
        if infoChanged, hasChatCtrl(), ChatModel.shared.chatInitialized {
            do { try apiSetNetworkInfo(info) }
            catch { logger.error("XauXat could not update core network availability") }
        }
    }

    private func networkTypeFromPath(_ path: NWPath) -> UserNetworkType {
        if path.usesInterfaceType(.wiredEthernet) {
            .ethernet
        } else if path.usesInterfaceType(.wifi) {
            .wifi
        } else if path.usesInterfaceType(.cellular) {
            .cellular
        } else if path.usesInterfaceType(.other) {
            .other
        } else {
            .none
        }
    }
}
