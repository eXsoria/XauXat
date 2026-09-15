//
//  AppSheet.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 24/11/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI

class AppSheetState: ObservableObject {
    static let shared = AppSheetState()
    @Published var scenePhaseActive: Bool = false

    func redactionReasons(_ protectScreen: Bool) -> RedactionReasons {
        !protectScreen || scenePhaseActive
        ? RedactionReasons()
        : RedactionReasons.placeholder
    }
}

struct XauXatAppSwitcherProtection: ViewModifier {
    @ObservedObject private var appSheetState = AppSheetState.shared

    func body(content: Content) -> some View {
        ZStack {
            content
            if !appSheetState.scenePhaseActive {
                Color.black
                    .ignoresSafeArea()
                    .accessibilityLabel("XauXat is hidden while inactive")
            }
        }
    }
}

struct XauXatPressToPreview<ProtectedContent: View, Placeholder: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var touchDown = false
    @State private var accessibilityReveal = false
    @State private var screenCaptured = UIScreen.main.isCaptured
    @State private var accessibilityTask: Task<Void, Never>?

    let onReveal: () -> Void
    let onHide: () -> Void
    @ViewBuilder let protectedContent: () -> ProtectedContent
    @ViewBuilder let placeholder: () -> Placeholder

    private var revealed: Bool {
        scenePhase == .active && !screenCaptured && (touchDown || accessibilityReveal)
    }

    var body: some View {
        ZStack {
            if revealed {
                protectedContent()
                    .privacySensitive()
                    .accessibilityAction(named: Text("Hide protected content")) {
                        hide()
                    }
            } else {
                placeholder()
                    .accessibilityAction(named: Text("Reveal protected content for ten seconds")) {
                        revealForAccessibility()
                    }
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(
            minimumDuration: .infinity,
            maximumDistance: 36,
            perform: {},
            onPressingChanged: { pressing in
                accessibilityTask?.cancel()
                accessibilityReveal = false
                touchDown = pressing && scenePhase == .active && !screenCaptured
            }
        )
        .onChange(of: revealed) { isRevealed in
            if isRevealed { onReveal() } else { onHide() }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            screenCaptured = UIScreen.main.isCaptured
            if screenCaptured { hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            hide()
        }
        .onDisappear { hide() }
    }

    private func revealForAccessibility() {
        guard scenePhase == .active && !screenCaptured else { return }
        accessibilityTask?.cancel()
        touchDown = false
        accessibilityReveal = true
        UIAccessibility.post(notification: .announcement, argument: NSLocalizedString("Protected content revealed for ten seconds", comment: "accessibility"))
        accessibilityTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { hide() }
        }
    }

    private func hide() {
        accessibilityTask?.cancel()
        accessibilityTask = nil
        touchDown = false
        accessibilityReveal = false
    }
}

private struct PrivacySensitive: ViewModifier {
    @AppStorage(DEFAULT_PRIVACY_PROTECT_SCREEN) private var protectScreen = false
    // Screen protection doesn't work for appSheet on iOS 16 if @Environment(\.scenePhase) is used instead of global state
    @ObservedObject var appSheetState: AppSheetState = AppSheetState.shared

    func body(content: Content) -> some View {
        content
            .redacted(reason: appSheetState.redactionReasons(protectScreen))
            .modifier(XauXatAppSwitcherProtection())
    }
}

extension View {
    func appSheet<Content>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View where Content: View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().modifier(PrivacySensitive())
        }
    }

    func appSheet<T, Content>(
        item: Binding<T?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View where T: Identifiable, Content: View {
        sheet(item: item, onDismiss: onDismiss) { it in
            content(it).modifier(PrivacySensitive())
        }
    }
}
