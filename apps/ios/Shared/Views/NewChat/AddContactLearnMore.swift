//
//  AddContactLearnMore.swift
//  SimpleX (iOS)
//
//  Created by spaced4ndy on 27.04.2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//

import SwiftUI

struct AddContactLearnMore: View {
    @Environment(\.dismiss) private var dismiss

    var showTitle: Bool
    var showCloseButton: Bool = false

    var body: some View {
        List {
            if showTitle {
                Text("One-time invitation link")
                    .font(.largeTitle)
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("To connect, your contact can scan QR code or use the link in the app.")
                Text("If you can't meet in person, show QR code in a video call, or share the link.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        .modifier(ThemedBackground(grouped: true))
        .overlay(alignment: .topTrailing) {
            if showCloseButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(
                            Color(
                                red: 222 / 255,
                                green: 206 / 255,
                                blue: 175 / 255
                            )
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .padding(.trailing, 16)
                .accessibilityLabel("Close")
                .zIndex(100)
            }
        }
    }
}

struct AddContactLearnMore_Previews: PreviewProvider {
    static var previews: some View {
        AddContactLearnMore(showTitle: true)
    }
}
