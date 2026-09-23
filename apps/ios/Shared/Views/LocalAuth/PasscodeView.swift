//
//  PasscodeView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 11/04/2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//
// Spec: spec/architecture.md

import SwiftUI

struct PasscodeView: View {
    @Binding var passcode: String
    var title: LocalizedStringKey
    var reason: String? = nil
    var submitLabel: LocalizedStringKey
    var submitEnabled: ((String) -> Bool)?
    var showsSubmitButton = true
    var expectedPasscodeLength: Int? = nil
    @Binding var buttonsEnabled: Bool

    var submit: () -> Void
    var cancel: () -> Void

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < geometry.size.height * 2 / 3 {
                portraitLayout(geometry)
            } else {
                landscapeLayout(geometry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
    }

    private func portraitLayout(_ geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            heading
                .padding(.top, 34)

            Spacer(minLength: 22)

            PasscodeEntry(
                width: min(geometry.size.width - 40, 390),
                height: geometry.size.height * 0.62,
                password: $passcode,
                expectedPasscodeLength: expectedPasscodeLength,
                buttonsEnabled: buttonsEnabled
            )

            Spacer(minLength: 18)

            actions
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    private func landscapeLayout(_ geometry: GeometryProxy) -> some View {
        HStack(spacing: 28) {
            VStack(spacing: 24) {
                heading
                passcodeIndicators
                actions
            }
            .frame(maxWidth: geometry.size.width * 0.34)

            PasscodeEntry(
                width: geometry.size.width * 0.58,
                height: geometry.size.height - 28,
                password: $passcode,
                expectedPasscodeLength: nil,
                showsIndicators: false,
                buttonsEnabled: buttonsEnabled
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var heading: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var passcodeIndicators: some View {
        PasscodeIndicators(passwordLength: passcode.count, expectedLength: expectedPasscodeLength)
    }

    private var actions: some View {
        HStack(spacing: 36) {
            Button("Cancel", action: cancel)
                .disabled(!buttonsEnabled)

            if showsSubmitButton {
                Button(submitLabel, action: submit)
                    .font(.body.weight(.semibold))
                    .disabled(submitEnabled?(passcode) == false || passcode.count < 4 || !buttonsEnabled)
            }
        }
        .font(.body)
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .frame(minHeight: 44)
    }
}

struct PasscodeIndicators: View {
    let passwordLength: Int
    let expectedLength: Int?

    var body: some View {
        if indicatorCount <= 8 {
            HStack(spacing: 15) {
                ForEach(0..<indicatorCount, id: \.self) { index in
                    Circle()
                        .fill(index < passwordLength ? Color.primary : Color.clear)
                        .overlay {
                            Circle().stroke(Color.primary.opacity(0.7), lineWidth: 1.5)
                        }
                        .frame(width: 12, height: 12)
                }
            }
            .frame(height: 20)
            .accessibilityLabel("Passcode")
            .accessibilityValue("\(passwordLength) digits entered")
        } else {
            Text(String(repeating: "●", count: passwordLength))
                .font(.system(.body, design: .rounded))
                .tracking(7)
                .frame(height: 20)
                .accessibilityLabel("Passcode")
                .accessibilityValue("\(passwordLength) digits entered")
        }
    }

    private var indicatorCount: Int {
        max(expectedLength ?? max(passwordLength, 6), 4)
    }
}

struct PasscodeViewView_Previews: PreviewProvider {
    static var previews: some View {
        PasscodeView(
            passcode: Binding.constant("12"),
            title: "Enter Passcode",
            reason: "Unlock app",
            submitLabel: "Submit",
            showsSubmitButton: false,
            expectedPasscodeLength: 6,
            buttonsEnabled: Binding.constant(true),
            submit: {},
            cancel: {}
        )
    }
}
