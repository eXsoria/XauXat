//
//  SendMessageView.swift
//  SimpleX
//
//  Created by Evgeny Poberezkin on 29/01/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

private let liveMsgInterval: UInt64 = 3000_000000

// Spec: spec/client/compose.md#SendMessageView
struct SendMessageView: View {
    var placeholder: String?
    @Binding var composeState: ComposeState
    @Binding var selectedRange: NSRange
    @EnvironmentObject var theme: AppTheme
    @Environment(\.isEnabled) var isEnabled
    var sendMessage: (Int?) -> Void
    var sendSignedMessage: () -> Void = {}
    var sendLiveMessage: (() async -> Void)? = nil
    var updateLiveMessage: (() async -> Void)? = nil
    var cancelLiveMessage: (() -> Void)? = nil
    var sendToConnect: (() -> Void)? = nil
    var hideSendButton: Bool = false
    var showVoiceMessageButton: Bool = true
    var voiceMessageAllowed: Bool = true
    var disableSendButton = false
    var showEnableVoiceMessagesAlert: ChatInfo.ShowEnableVoiceMessagesAlert = .other
    var voiceInteraction = VoiceRecordingInteraction()
    var voiceRecordingTime: TimeInterval = 0
    var voiceRecordingLevels: [CGFloat] = []
    var startVoiceMessageRecording: ((Bool) -> Void)? = nil
    var moveVoiceMessageRecording: ((Double, Double) -> Void)? = nil
    var releaseVoiceMessageRecording: ((VoiceRecordingTouchTiming) -> Void)? = nil
    var cancelVoiceMessageTouch: ((VoiceRecordingTouchTiming) -> Void)? = nil
    var discardVoiceMessageRecording: (() -> Void)? = nil
    var finishVoiceMessageRecording: (() -> Void)? = nil
    var allowVoiceMessagesToContact: (() -> Void)? = nil
    var timedMessageAllowed: Bool = false
    var showSign: Bool = false
    var onMediaAdded: ([UploadContent]) -> Void
    @Namespace var namespace
    @Binding var keyboardVisible: Bool
    @Binding var keyboardHiddenDate: Date
    var composerIconColor = Color.accentColor
    var editorAccessories: AnyView? = nil
    var voiceAccessories: AnyView? = nil
    var listenOnce: Binding<Bool>? = nil
    var sendVoiceRecording: (() -> Void)? = nil
    var sendButtonColor = Color.accentColor
    @State private var teHeight: CGFloat = NativeTextEditor.minHeight
    @State private var teFont: Font = .body
    @State private var sendButtonSize: CGFloat = 29
    @State private var sendButtonOpacity: CGFloat = 1
    @State private var showCustomDisappearingMessageDialogue = false
    @State private var showCustomTimePicker = false
    @State private var selectedDisappearingMessageTime: Int? = customDisappearingMessageTimeDefault.get()
    @UserDefault(DEFAULT_LIVE_MESSAGE_ALERT_SHOWN) private var liveMessageAlertShown = false
    @UserDefault(DEFAULT_SIGN_MESSAGE_ALERT_SHOWN) private var signMessageAlertShown = false

    var body: some View {
        let showingVoice = voiceInteraction.active || composeState.voicePreview
        let showsIdleAccessories = composeState.noPreview && composeState.message.isEmpty && !composeState.editing
            && !composeState.forwarding && composeState.liveMessage == nil && !hideSendButton
        let holdOrIdle = showsIdleAccessories || voiceInteraction.active
        let composeShape = RoundedRectangle(cornerRadius: 21)

        HStack(alignment: .bottom, spacing: 4) {
            ZStack(alignment: .leading) {
                HStack(alignment: .bottom, spacing: 0) {
                    // Preserve the native editor and its first responder during a held touch.
                    NativeTextEditor(
                        text: $composeState.message,
                        disableEditing: $composeState.inProgress,
                        height: $teHeight,
                        focused: $keyboardVisible,
                        lastUnfocusedDate: $keyboardHiddenDate,
                        placeholder: Binding(get: { placeholder ?? composeState.placeholder }, set: { _ in }),
                        selectedRange: $selectedRange,
                        onImagesAdded: onMediaAdded,
                        blocksInput: showingVoice || composeState.progressByTimeout
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    if let editorAccessories, !composeState.editing && !composeState.forwarding {
                        editorAccessories
                            .opacity(showingVoice || composeState.progressByTimeout ? 0 : 1)
                            .allowsHitTesting(!showingVoice && !composeState.progressByTimeout)
                            .accessibilityHidden(showingVoice || composeState.progressByTimeout)
                    }
                }

                if composeState.progressByTimeout {
                    Text("Encrypting…").font(.caption.weight(.medium)).foregroundColor(theme.colors.secondary)
                        .padding(.horizontal, 12)
                } else if voiceInteraction.active {
                    VoiceRecordingStatus(interaction: voiceInteraction, time: voiceRecordingTime, levels: voiceRecordingLevels, color: sendButtonColor, deleteRecording: discardVoiceMessageRecording, listenOnce: listenOnce)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                } else if composeState.voicePreview {
                    Text("Voice message…").font(.callout.italic()).foregroundColor(theme.colors.secondary)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(theme.colors.background, in: composeShape)
            .overlay(composeShape.strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false))
            .overlay(alignment: .topTrailing) {
                if !showingVoice && !composeState.progressByTimeout && teHeight > 100 && !composeState.inProgress {
                    deleteTextButton()
                }
            }

            if let voiceAccessories, holdOrIdle {
                voiceAccessories
                    .frame(maxWidth: voiceInteraction.active ? 0 : nil)
                    .opacity(showsIdleAccessories && !voiceInteraction.active ? 1 : 0)
                    .allowsHitTesting(showsIdleAccessories && !voiceInteraction.active)
                    .accessibilityHidden(voiceInteraction.active)
            }
            if !composeState.progressByTimeout {
                composeActionButtons()
            }
        }
        .onChange(of: composeState.message, perform: { text in updateFont(text) })
        .padding(.vertical, 4)
    }

    @ViewBuilder private func composeActionButtons() -> some View {
        let vmrs = composeState.voiceMessageRecordingState
        if hideSendButton {
            EmptyView()
        } else if let connect = sendToConnect {
            sendToConnectButton(connect)
        } else if case .reportedItem = composeState.contextItem {
            sendMessageButton()
        } else if showVoiceMessageButton
            && composeState.message.isEmpty
            && !composeState.editing
            && !composeState.forwarding
            && composeState.liveMessage == nil
            && ((composeState.noPreview && vmrs == .noRecording)
                || voiceInteraction.active) {
            HStack(spacing: 2) {
                if voiceInteraction.phase == .locked, voiceInteraction.ready, let sendVoiceRecording {
                    Button(action: sendVoiceRecording) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 35))
                            .frame(width: 42, height: 44)
                    }
                    .foregroundColor(sendButtonColor)
                    .accessibilityLabel("Send recording")
                } else if editorAccessories == nil, let send = sendLiveMessage,
                          let update = updateLiveMessage,
                          case .noContextItem = composeState.contextItem {
                    startLiveMessageButton(send: send, update: update)
                        .opacity(voiceInteraction.active ? 0 : 1)
                        .disabled(voiceInteraction.active)
                        .accessibilityHidden(voiceInteraction.active)
                }
                if voiceMessageAllowed {
                    VoiceRecordingButton(
                        interaction: voiceInteraction,
                        color: composerIconColor,
                        disabled: composeState.inProgress || !isEnabled,
                        begin: { startVoiceMessageRecording?($0) },
                        move: { moveVoiceMessageRecording?($0, $1) },
                        release: { releaseVoiceMessageRecording?($0) },
                        cancelTouch: { cancelVoiceMessageTouch?($0) },
                        pause: { finishVoiceMessageRecording?() }
                    )
                    .padding(.trailing, 2)
                } else {
                    voiceMessageNotAllowedButton()
                }

            }
        } else if vmrs == .recording {
            finishVoiceMessageRecordingButton()
        } else if composeState.liveMessage != nil && composeState.liveMessage?.sentMsg == nil && composeState.message.isEmpty {
            cancelLiveMessageButton {
                cancelLiveMessage?()
            }
        } else {
            sendMessageButton()
        }
    }

    private func deleteTextButton() -> some View {
        Button {
            composeState.message = ""
        } label: {
            Image(systemName: "multiply.circle.fill")
        }
        .foregroundColor(Color(uiColor: .tertiaryLabel))
        .padding([.top, .trailing], 4)
    }

    private func sendToConnectButton(_ connect: @escaping () -> Void) -> some View {
        let disabled = !composeState.sendEnabled || composeState.inProgress || disableSendButton
        return Button(action: connect) {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .foregroundColor(disabled ? theme.colors.secondary.opacity(0.67) : sendButtonColor)
                .frame(width: sendButtonSize, height: sendButtonSize)
                .opacity(sendButtonOpacity)
        }
        .disabled(disabled)
        .frame(width: 31, height: 31)
        .padding([.bottom, .trailing], 4)
    }

    private func sendMessageButton() -> some View {
        Button {
            sendMessage(nil)
        } label: {
            Image(systemName: composeState.editing || composeState.liveMessage != nil
                  ? "checkmark.circle.fill"
                  : "arrow.up.circle.fill")
            .resizable()
            .foregroundColor(sendButtonColor)
            .frame(width: sendButtonSize, height: sendButtonSize)
            .opacity(sendButtonOpacity)
        }
        .disabled(
            !composeState.sendEnabled ||
            composeState.inProgress ||
            (!voiceMessageAllowed && composeState.voicePreview) ||
            composeState.endLiveDisabled ||
            disableSendButton
        )
        .frame(width: 31, height: 31)
        .contextMenu{
            sendButtonContextMenuItems()
        }
        .padding([.bottom, .trailing], 4)
        .confirmationDialog("Send disappearing message", isPresented: $showCustomDisappearingMessageDialogue, titleVisibility: .visible) {
            Button("30 seconds") { sendMessage(30) }
            Button("1 minute") { sendMessage(60) }
            Button("5 minutes") { sendMessage(300) }
            Button("Custom time") { showCustomTimePicker = true }
        }
        .sheet(isPresented: $showCustomTimePicker, onDismiss: { selectedDisappearingMessageTime = customDisappearingMessageTimeDefault.get() }) {
            if #available(iOS 16.0, *) {
                disappearingMessageCustomTimePicker()
                    .presentationDetents([.medium])
            } else {
                disappearingMessageCustomTimePicker()
            }
        }
    }

    private func disappearingMessageCustomTimePicker() -> some View {
        CustomTimePickerView(
            selection: $selectedDisappearingMessageTime,
            confirmButtonText: "Send",
            confirmButtonAction: {
                if let time = selectedDisappearingMessageTime {
                    sendMessage(time)
                    customDisappearingMessageTimeDefault.set(time)
                }
            },
            description: "Delete after"
        )
    }

    @ViewBuilder private func sendButtonContextMenuItems() -> some View {
        if composeState.liveMessage == nil,
           !composeState.editing {
            if case .noContextItem = composeState.contextItem,
               !composeState.voicePreview,
               !composeState.manyMediaPreviews,
               let send = sendLiveMessage,
               let update = updateLiveMessage {
                Button {
                    startLiveMessage(send: send, update: update)
                } label: {
                    Label("Send live message", systemImage: "bolt.fill")
                }
            }
            if timedMessageAllowed {
                Button {
                    hideKeyboard()
                    showCustomDisappearingMessageDialogue = true
                } label: {
                    Label("Disappearing message", systemImage: "stopwatch")
                }
            }
            // hidden until message signing is user-facing (recipient-only stage)
//            if showSign {
//                Button {
//                    startSignedMessage()
//                } label: {
//                    Label("Sign message", systemImage: "checkmark.seal")
//                }
//            }
        }
    }

    private func voiceMessageNotAllowedButton() -> some View {
        Button {
            switch showEnableVoiceMessagesAlert {
            case .userEnable:
                AlertManager.shared.showAlert(Alert(
                    title: Text("Allow voice messages?"),
                    message: Text("You need to allow your contact to send voice messages to be able to send them."),
                    primaryButton: .default(Text("Allow")) {
                        allowVoiceMessagesToContact?()
                    },
                    secondaryButton: .cancel()
                ))
            case .askContact:
                AlertManager.shared.showAlertMsg(
                    title: "Voice messages prohibited!",
                    message: "Please ask your contact to enable sending voice messages."
                )
            case .groupOwnerCan:
                AlertManager.shared.showAlertMsg(
                    title: "Voice messages prohibited!",
                    message: "Only group owners can enable voice messages."
                )
            case .other:
                AlertManager.shared.showAlertMsg(
                    title: "Voice messages prohibited!",
                    message: "Please check yours and your contact preferences."
                )
            }
        } label: {
            Image(systemName: "mic")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundColor(theme.colors.secondary)
        }
        .disabled(composeState.inProgress)
        .frame(width: 31, height: 31)
        .padding([.bottom, .trailing], 4)
    }

    private func cancelLiveMessageButton(cancel: @escaping () -> Void) -> some View {
        return Button {
            cancel()
        } label: {
            Image(systemName: "multiply")
                .resizable()
                .scaledToFit()
                .foregroundColor(theme.colors.primary)
                .frame(width: 15, height: 15)
        }
        .frame(width: 29, height: 29)
        .padding([.bottom, .horizontal], 4)
    }

    private func startLiveMessageButton(send:  @escaping () async -> Void, update: @escaping () async -> Void) -> some View {
        return Button {
            switch composeState.preview {
            case .noPreview: startLiveMessage(send: send, update: update)
            default: ()
            }
        } label: {
            Image(systemName: "bolt.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(isEnabled ? composerIconColor : theme.colors.secondary)
                .frame(width: 20, height: 20)
        }
        .frame(width: 29, height: 29)
        .padding([.bottom, .horizontal], 4)
    }

    private func startSignedMessage() {
        if signMessageAlertShown {
            sendSignedMessage()
        } else {
            AlertManager.shared.showAlert(Alert(
                title: Text("Sign message"),
                message: Text("Signing proves you authored this message and can't be denied later."),
                primaryButton: .default(Text("Send")) {
                    signMessageAlertShown = true
                    sendSignedMessage()
                },
                secondaryButton: .cancel()
            ))
        }
    }

    private func startLiveMessage(send:  @escaping () async -> Void, update: @escaping () async -> Void) {
        if liveMessageAlertShown {
            start()
        } else {
            AlertManager.shared.showAlert(Alert(
                title: Text("Live message!"),
                message: Text("Send a live message - it will update for the recipient(s) as you type it"),
                primaryButton: .default(Text("Send")) {
                    liveMessageAlertShown = true
                    start()
                },
                secondaryButton: .cancel()
            ))
        }

        func start() {
            Task {
                await send()
                await MainActor.run { run() }
            }
        }

        @Sendable func run() {
            Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { t in
                withAnimation(.easeInOut(duration: 0.7)) {
                    sendButtonSize = sendButtonSize == 29 ? 26 : 29
                    sendButtonOpacity = sendButtonOpacity == 1 ? 0.75 : 1
                }
                if composeState.liveMessage == nil {
                    t.invalidate()
                    sendButtonSize = 29
                    sendButtonOpacity = 1
                }
            }
            Task {
                _ = try? await Task.sleep(nanoseconds: liveMsgInterval)
                while await composeState.liveMessage != nil {
                    await update()
                    _ = try? await Task.sleep(nanoseconds: liveMsgInterval)
                }
            }
        }
    }

    private func finishVoiceMessageRecordingButton() -> some View {
        Button(action: { finishVoiceMessageRecording?() }) {
            Image(systemName: "stop.fill")
                .foregroundColor(theme.colors.primary)
        }
        .disabled(composeState.inProgress)
        .frame(width: 31, height: 31)
        .padding([.bottom, .trailing], 4)
    }

    private func updateFont(_ text: String) {
        DispatchQueue.main.async {
            teFont = isShortEmoji(text)
            ? (text.count < 4 ? largeEmojiFont : mediumEmojiFont)
            : .body
        }
    }
}

struct SendMessageView_Previews: PreviewProvider {
    static var previews: some View {
        @State var composeStateNew = ComposeState()
        @State var selectedRange = NSRange()
        let ci = ChatItem.getSample(1, .directSnd, .now, "hello")
        @State var composeStateEditing = ComposeState(editingItem: ci)
        @State var selectedRangeEditing = NSRange()
        @State var sendEnabled: Bool = true

        return Group {
            VStack {
                Text("")
                Spacer(minLength: 0)
                SendMessageView(
                    composeState: $composeStateNew,
                    selectedRange: $selectedRange,
                    sendMessage: { _ in },
                    onMediaAdded: { _ in },
                    keyboardVisible: Binding.constant(true),
                    keyboardHiddenDate: Binding.constant(Date.now)
                )
            }
            VStack {
                Text("")
                Spacer(minLength: 0)
                SendMessageView(
                    composeState: $composeStateEditing,
                    selectedRange: $selectedRangeEditing,
                    sendMessage: { _ in },
                    onMediaAdded: { _ in },
                    keyboardVisible: Binding.constant(true),
                    keyboardHiddenDate: Binding.constant(Date.now)
                )
            }
        }
    }
}
