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
    private let queue: DispatchQueue = DispatchQueue(label: "pt.exsoria.xauxat.NetworkObserver")
    private var prevInfo: UserNetworkInfo? = nil
    private var monitor: NWPathMonitor?
    private let monitorLock: DispatchQueue = DispatchQueue(label: "pt.exsoria.xauxat.monitorLock")

    func restartMonitor() {
        monitorLock.sync {
            monitor?.cancel()
            let mon = NWPathMonitor()
            mon.pathUpdateHandler = { [weak self] path in
                self?.networkPathChanged(path: path)
            }
            mon.start(queue: queue)
            monitor = mon
        }
    }

    private func networkPathChanged(path: NWPath) {
        let info = UserNetworkInfo(
            networkType: networkTypeFromPath(path),
            online: path.status == .satisfied
        )
        if (prevInfo != info) {
            prevInfo = info
            setNetworkInfo(info)
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

    private static var networkObserver: NetworkObserver? = nil

    private func setNetworkInfo(_ info: UserNetworkInfo) {
        logger.debug("setNetworkInfo Network changed: \(String(describing: info))")
        DispatchQueue.main.sync {
            ChatModel.shared.networkInfo = info
        }
        if !hasChatCtrl() { return }
        self.monitorLock.sync {
            do {
                try apiSetNetworkInfo(info)
            } catch let err {
                logger.error("setNetworkInfo error: \(responseError(err))")
            }
        }
        // Revalidate Tor when Wi-Fi/mobile connectivity changes while XauXat
        // stays open; foreground-only checks miss this case. Initial bootstrap
        // still belongs to SimpleXApp, before a chat controller exists.
        DispatchQueue.main.async {
            guard info.online, ChatModel.shared.chatRunning == true,
                  AppChatState.shared.value == .active else { return }
            Task {
                do { try await reconnectAllServers() }
                catch { logger.error("XauXat could not recover its private route after a network change") }
            }
        }
    }
}
