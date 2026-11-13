//
//  IncomingCallView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 24/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct IncomingCallView: View {
    @EnvironmentObject var m: ChatModel
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject var cc = CallController.shared

    var body: some View {
        let sp = SoundPlayer.shared
        if let invitation = cc.activeCallInvitation {
            if m.showCallView {
                incomingCall(invitation)
            } else {
                incomingCall(invitation)
                .onAppear { sp.startRingtone() }
                .onDisappear { sp.stopRingtone() }
            }
        }
    }

    private func incomingCall(_ invitation: RcvCallInvitation) -> some View {
        Group {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 12) {
                    caller(invitation)
                    actions(invitation)
                }
            } else {
                HStack(spacing: 10) {
                    caller(invitation)
                    Spacer(minLength: 0)
                    actions(invitation)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(.black, in: RoundedRectangle(cornerRadius: sizeCategory.isAccessibilityCategory ? 28 : 32))
        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
            if drag.translation.height < -24, abs(drag.translation.height) > abs(drag.translation.width) {
                cc.activeCallInvitation = nil
            }
        })
        .accessibilityAction(named: Text("Ignore call")) { cc.activeCallInvitation = nil }
        .onAppear { dismissAllSheets() }
    }

    private func caller(_ invitation: RcvCallInvitation) -> some View {
        HStack(spacing: 8) {
            ProfileImage(imageStr: invitation.contact.image, size: 42, color: .white,
                         backgroundColor: Color(white: 0.24), radiusOverride: 1)
                .overlay(alignment: .bottomTrailing) {
                    if m.users.count > 1 {
                        ProfileImage(imageStr: invitation.user.image, size: 16, color: .white,
                                     backgroundColor: .black, radiusOverride: 1)
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(invitation.sharedKey == nil ? "No E2E encryption" : "E2E encrypted")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.72))
                Text(invitation.contact.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
            }
            .lineLimit(sizeCategory.isAccessibilityCategory ? 2 : 1)
            .accessibilityElement(children: .combine)
        }
    }

    private func actions(_ invitation: RcvCallInvitation) -> some View {
        HStack(spacing: 8) {
            callButton("Decline", Image(systemName: "phone.down.fill"), Color(red: 0.74, green: 0.16, blue: 0.20)) {
                cc.endCall(invitation: invitation)
            }
            callButton("Accept", Image(systemName: "phone.fill"), Color(red: 0.08, green: 0.50, blue: 0.25)) {
                answer(invitation, startWithModifiedVoice: false)
            }
            #if DEBUG
            if !CallController.useCallKit() {
                callButton("Answer with voice mask", Image("xauxat-mask"),
                           Color(red: 0.87, green: 0.81, blue: 0.69), foreground: .black) {
                    answer(invitation, startWithModifiedVoice: true)
                }
            }
            #endif
        }
        .fixedSize()
    }

    private func answer(_ invitation: RcvCallInvitation, startWithModifiedVoice: Bool) {
        if let call = m.activeCall {
            cc.endCall(call: call) {
                DispatchQueue.main.async {
                    cc.answerCall(invitation: invitation, startWithModifiedVoice: startWithModifiedVoice)
                }
            }
        } else {
            cc.answerCall(invitation: invitation, startWithModifiedVoice: startWithModifiedVoice)
        }
    }

    private func callButton(_ text: LocalizedStringKey, _ image: Image, _ color: Color,
                            foreground: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            image
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 21, height: 21)
                .foregroundColor(foreground)
                .frame(width: 44, height: 44)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(text))
    }
}

struct IncomingCallView_Previews: PreviewProvider {
    static var previews: some View {
        CallController.shared.activeCallInvitation = RcvCallInvitation.sampleData
        let m = ChatModel()
        m.users = [UserInfo.sampleData, UserInfo.sampleData]
        return IncomingCallView().environmentObject(m)
    }
}
