//
//  PasscodeEntry.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 10/04/2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//
// Spec: spec/architecture.md

import SwiftUI

struct PasscodeEntry: View {
    var width: CGFloat
    var height: CGFloat
    @Binding var password: String
    var expectedPasscodeLength: Int? = nil
    var showsIndicators = true

    var body: some View {
        VStack(spacing: 22) {
            if showsIndicators {
                PasscodeIndicators(passwordLength: password.count, expectedLength: expectedPasscodeLength)
            }

            if width < height * 2 / 3 {
                portraitKeypad
            } else {
                landscapeKeypad
            }
        }
    }

    private var portraitKeypad: some View {
        let keySize = min((width - 72) / 3, 78)
        return VStack(spacing: 15) {
            digitRow(keySize, 1, 2, 3)
            digitRow(keySize, 4, 5, 6)
            digitRow(keySize, 7, 8, 9)
            HStack(spacing: 24) {
                clearButton(keySize)
                digitButton(keySize, 0)
                deleteButton(keySize)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var landscapeKeypad: some View {
        let keySize = min((height - 24) / 3, (width - 72) / 4, 64)
        return VStack(spacing: 10) {
            HStack(spacing: 18) {
                digitButton(keySize, 1)
                digitButton(keySize, 2)
                digitButton(keySize, 3)
                clearButton(keySize)
            }
            HStack(spacing: 18) {
                digitButton(keySize, 4)
                digitButton(keySize, 5)
                digitButton(keySize, 6)
                digitButton(keySize, 0)
            }
            HStack(spacing: 18) {
                digitButton(keySize, 7)
                digitButton(keySize, 8)
                digitButton(keySize, 9)
                deleteButton(keySize)
            }
        }
    }

    private func digitRow(_ size: CGFloat, _ first: Int, _ second: Int, _ third: Int) -> some View {
        HStack(spacing: 24) {
            digitButton(size, first)
            digitButton(size, second)
            digitButton(size, third)
        }
    }

    private func digitButton(_ size: CGFloat, _ digit: Int) -> some View {
        keypadButton(size: size, action: appendDigit(digit)) {
            Text(String(digit))
                .font(.system(size: min(size * 0.42, 34), weight: .regular, design: .rounded))
        }
        .accessibilityLabel(String(digit))
        .disabled(password.count >= 16)
    }

    private func clearButton(_ size: CGFloat) -> some View {
        Button {
            password = ""
        } label: {
            Text(password.isEmpty ? "" : "Clear")
                .font(.callout)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .disabled(password.isEmpty)
        .accessibilityLabel("Clear passcode")
    }

    private func deleteButton(_ size: CGFloat) -> some View {
        Button {
            if !password.isEmpty { password.removeLast() }
        } label: {
            Image(systemName: "delete.backward")
                .font(.system(size: min(size * 0.3, 24), weight: .regular))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .disabled(password.isEmpty)
        .accessibilityLabel("Delete digit")
    }

    private func keypadButton<Label: View>(size: CGFloat, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .foregroundColor(.primary)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(0.09))
                }
                .contentShape(Circle())
        }
        .buttonStyle(XauXatKeypadButtonStyle())
    }

    private func appendDigit(_ digit: Int) -> () -> Void {
        {
            guard password.count < 16 else { return }
            password.append(String(digit))
        }
    }
}

private struct XauXatKeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct PasscodeEntry_Previews: PreviewProvider {
    static var previews: some View {
        PasscodeEntry(width: 390, height: 620, password: Binding.constant("12"), expectedPasscodeLength: 6)
    }
}
