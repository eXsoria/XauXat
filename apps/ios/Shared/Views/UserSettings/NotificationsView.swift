//
//  NotificationsView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 26/06/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct NotificationsView: View {
    @EnvironmentObject var m: ChatModel
    @EnvironmentObject var theme: AppTheme
    @State private var notificationMode: NotificationsMode = ChatModel.shared.notificationMode
    @State private var ntfAlert: NotificationAlert?
    @State private var legacyDatabase = dbContainerGroupDefault.get() == .documents
    @State private var testing = false
    @State private var testedSuccess: Bool? = nil

    var body: some View {
        ZStack {
            viewBody()
            if testing {
                ProgressView().scaleEffect(2)
            }
        }
        .alert(item: $ntfAlert) { alert in notificationAlert(alert) }
    }

    private func viewBody() -> some View {
        List {
            Section {
                NavigationLink {
                    List {
                        Section {
                            SelectionListView(list: NotificationsMode.values, selection: $notificationMode) { mode in
                                if mode != .off && !xauXatNotificationServerConfigured {
                                    ntfAlert = .error(
                                        title: "Push notifications unavailable",
                                        error: "This build has no XauXat notification server. No third-party server will be used as a fallback."
                                    )
                                } else {
                                    ntfAlert = .setMode(mode: mode)
                                }
                            }
                        } footer: {
                            VStack(alignment: .leading) {
                                Text(ntfModeDescription(notificationMode))
                                    .foregroundColor(theme.colors.secondary)
                            }
                            .font(.callout)
                            .padding(.top, 1)
                        }
                    }
                    .navigationTitle("Send notifications")
                    .modifier(ThemedBackground(grouped: true))
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("Send notifications")
                        Spacer()
                        Text(m.notificationMode.label)
                    }
                }

                if let server = m.notificationServer {
                    smpServers("Push server", [server], theme.colors.secondary)
                    testTokenButton(server)
                }
            } header: {
                Text("Push notifications")
                    .foregroundColor(theme.colors.secondary)
            } footer: {
                if legacyDatabase {
                    Text("Please restart the app and migrate the database to enable push notifications.")
                        .foregroundColor(theme.colors.secondary)
                        .font(.callout)
                        .padding(.top, 1)
                } else if !xauXatNotificationServerConfigured {
                    Text("Push notifications are unavailable in this build. XauXat will not use a third-party notification server as a fallback.")
                        .foregroundColor(theme.colors.secondary)
                        .font(.callout)
                        .padding(.top, 1)
                }
            }
        }
        .disabled(legacyDatabase)
        .onAppear {
            (m.savedToken, m.tokenStatus, m.notificationMode, m.notificationServer) = apiGetNtfToken()
        }
    }

    private func notificationAlert(_ alert: NotificationAlert) -> Alert {
        switch alert {
        case let .setMode(mode):
            return Alert(
                title: Text(ntfModeAlertTitle(mode)),
                message: Text(notificationPrivacySummary(mode)),
                primaryButton: .default(Text(mode == .off ? "Turn off" : "I understand, enable")) {
                    setNotificationsMode(mode)
                },
                secondaryButton: .cancel() {
                    notificationMode = m.notificationMode
                }
            )
        case let .testFailure(testFailure):
            return Alert(
                title: Text("Server test failed!"),
                message: Text(testFailure.localizedDescription)
            )
        case let .error(title, error):
            return Alert(title: Text(title), message: Text(error))
        }
    }

    private func ntfModeAlertTitle(_ mode: NotificationsMode) -> LocalizedStringKey {
        switch mode {
        case .off: return "Use only local notifications?"
        case .periodic: return "Enable periodic notifications?"
        case .instant: return "Enable instant notifications?"
        }
    }

    private func setNotificationsMode(_ mode: NotificationsMode) {
        xauXatApplyNotificationMode(mode) { enabled in
            if enabled {
                notificationMode = mode
                testedSuccess = nil
            } else {
                notificationMode = m.notificationMode
                ntfAlert = .error(
                    title: "Notifications remain off",
                    error: "Allow notifications in iOS Settings before enabling them in XauXat."
                )
            }
        }
    }

    private func testTokenButton(_ server: String) -> some View {
        HStack {
            Button("Test notifications") {
                testing = true
                Task {
                    await testServerAndToken(server)
                    await MainActor.run { testing = false }
                }
            }
            .disabled(testing)
            if !testing {
                Spacer()
                showTestStatus()
            }
        }
    }

    @ViewBuilder func showTestStatus() -> some View {
        if testedSuccess == true {
            Image(systemName: "checkmark")
                .foregroundColor(.green)
        } else if testedSuccess == false {
            Image(systemName: "multiply")
                .foregroundColor(.red)
        }
    }

    private func testServerAndToken(_ server: String) async {
        do {
            let r = try await testProtoServer(server: server)
            switch r {
            case .success:
                if let token = m.deviceToken {
                    do {
                        let status = try await apiCheckToken(token: token)
                        await MainActor.run {
                            m.tokenStatus = status
                            testedSuccess = status.workingToken
                            if status.workingToken {
                                showAlert(
                                    NSLocalizedString("Notifications status", comment: "alert title"),
                                    message: tokenStatusInfo(status, register: false)
                                )
                            } else {
                                showAlert(
                                    title: NSLocalizedString("Notifications error", comment: "alert title"),
                                    message: tokenStatusInfo(status, register: true),
                                    buttonTitle: "Register",
                                    buttonAction: {
                                        reRegisterToken(token: token)
                                        testedSuccess = nil
                                    },
                                    cancelButton: true
                                )
                            }
                        }
                    } catch let error {
                        await MainActor.run {
                            let err = responseError(error)
                            logger.error("apiCheckToken \(err)")
                            ntfAlert = .error(title: "Error checking token status", error: err)
                        }
                    }
                } else {
                    await MainActor.run {
                        showAlert(
                            NSLocalizedString("No token!", comment: "alert title")
                        )
                    }
                }
            case let .failure(f):
                await MainActor.run {
                    ntfAlert = .testFailure(testFailure: f)
                    testedSuccess = false
                }
            }
        } catch let error {
            await MainActor.run {
                let err = responseError(error)
                logger.error("testServerConnection \(err)")
                ntfAlert = .error(title: "Error testing server connection", error: err)
            }
        }
    }
}

func ntfModeDescription(_ mode: NotificationsMode) -> LocalizedStringKey {
    switch mode {
    case .off: return "**Most private**: no APNs token is shared with the XauXat push service. Open XauXat to check for new messages."
    case .periodic: return "Periodic checks use Apple Push Notification service to wake XauXat. The XauXat push service receives the device token, but not subscriptions to individual message queues."
    case .instant: return "Instant alerts use Apple Push Notification service and the XauXat push service. Notification metadata is encrypted and does not contain message text or contact identity."
    }
}

func ntfModeShortDescription(_ mode: NotificationsMode) -> LocalizedStringKey {
    switch mode {
    case .off: return "No background alerts."
    case .periodic: return "Check messages every 20 min."
    case .instant: return "E2E encrypted notifications."
    }
}

func notificationPrivacySummary(_ mode: NotificationsMode) -> String {
    notificationPrivacyPoints(mode).joined(separator: "\n\n")
}

func notificationPrivacyPoints(_ mode: NotificationsMode) -> [String] {
    switch mode {
    case .off:
        return [String(localized: "No APNs token is shared with the XauXat push service. Open XauXat to check for new messages.")]
    case .periodic:
        return [
            String(localized: "Apple Push Notification service periodically wakes XauXat. This Apple delivery is outside Tor."),
            String(localized: "Apple can observe that this device receives pushes and their timing. The payload contains no message text or contact identity."),
            String(localized: "The XauXat push service receives the device APNs token, but not subscriptions to individual message queues."),
            String(localized: "Message retrieval uses XauXat's embedded Tor connection. Periodic checks can arrive late because iOS controls background timing.")
        ]
    case .instant:
        return [
            String(localized: "Apple Push Notification service delivers an encrypted wake-up signal. This Apple delivery is outside Tor."),
            String(localized: "Apple can observe that this device receives pushes and their timing. The payload contains no message text or contact identity."),
            String(localized: "The XauXat push service receives the device APNs token and separate notification queue subscriptions. It can infer how many queues have notifications enabled and approximate activity, but it does not receive message queue addresses."),
            String(localized: "When the extension wakes, message retrieval uses its own embedded Tor connection and fails closed if Tor is unavailable.")
        ]
    }
}

struct SelectionListView<Item: SelectableItem>: View {
    @EnvironmentObject var theme: AppTheme
    var list: [Item]
    @Binding var selection: Item
    var onSelection: ((Item) -> Void)?
    @State private var tapped: Item? = nil

    var body: some View {
        ForEach(list) { item in
            Button {
                if selection == item { return }
                if let f = onSelection {
                    f(item)
                } else {
                    selection = item
                }
            } label: {
                HStack {
                    Text(item.label).foregroundColor(theme.colors.onBackground)
                    Spacer()
                    if selection == item {
                        Image(systemName: "checkmark")
                            .resizable().scaledToFit().frame(width: 16)
                            .foregroundColor(theme.colors.primary)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }
}

enum NotificationAlert: Identifiable {
    case setMode(mode: NotificationsMode)
    case testFailure(testFailure: ProtocolTestFailure)
    case error(title: LocalizedStringKey, error: String)

    var id: String {
        switch self {
        case let .setMode(mode): return "enable \(mode.rawValue)"
        case let .testFailure(testFailure): return "testFailure \(testFailure.testStep) \(testFailure.testError)"
        case let .error(title, error): return "error \(title): \(error)"
        }
    }
}

struct NotificationsView_Previews: PreviewProvider {
    static var previews: some View {
        NotificationsView()
    }
}
