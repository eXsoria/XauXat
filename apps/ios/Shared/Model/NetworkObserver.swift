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
    private var monitor: NWPathMonitor?
    private var monitorGeneration = UUID()

    func restartMonitor() {
        queue.async { [self] in
            monitor?.cancel()
            let generation = UUID()
            monitorGeneration = generation
            prevInfo = nil
            let mon = NWPathMonitor()
            mon.pathUpdateHandler = { [weak self] path in
                guard let self, self.monitorGeneration == generation else { return }
                self.networkPathChanged(path: path)
            }
            monitor = mon
            mon.start(queue: queue)
        }
    }

    private func networkPathChanged(path: NWPath) {
        let info = UserNetworkInfo(
            networkType: networkTypeFromPath(path),
            online: path.status == .satisfied
        )
        let infoChanged = prevInfo != info
        prevInfo = info
        // A new path may still be Wi-Fi and online. Process every callback for
        // recovery; send core network-info updates only when those values change.
        DispatchQueue.main.async {
            ChatModel.shared.networkInfo = info
            XauXatConnectionRecoveryManager.shared.networkChanged(online: info.online)
        }
        if infoChanged, hasChatCtrl() {
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
