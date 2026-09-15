//
//  FramedCIVoiceView.swift
//  SimpleX (iOS)
//
//  Created by JRoberts on 22.11.2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/chat-view.md

import SwiftUI

import SwiftUI
import SimpleXChat

// Spec: spec/client/chat-view.md#FramedCIVoiceView
struct FramedCIVoiceView: View {
    @EnvironmentObject var theme: AppTheme
    @ObservedObject var chat: Chat
    var chatItem: ChatItem
    let recordingFile: CIFile?
    let duration: Int

    @State var audioPlayer: AudioPlayer? = nil
    @State var playbackState: VoiceMessagePlaybackState = .noPlayback
    @State var playbackTime: TimeInterval? = nil

    @Binding var allowMenu: Bool

    @State private var seek: (TimeInterval) -> Void = { _ in }
    
    var body: some View {
        HStack {
            VoiceMessagePlayer(
                chat: chat,
                chatItem: chatItem,
                recordingFile: recordingFile,
                recordingTime: TimeInterval(duration),
                showBackground: false,
                seek: $seek,
                audioPlayer: $audioPlayer,
                playbackState: $playbackState,
                playbackTime: $playbackTime,
                allowMenu: $allowMenu,
                sizeMultiplier: 1
            )
            VoiceMessagePlayerTime(
                recordingTime: TimeInterval(duration),
                playbackState: $playbackState,
                playbackTime: $playbackTime
            )
            .foregroundColor(theme.colors.secondary)
            .frame(width: 50, alignment: .leading)
            if .playing == playbackState || (playbackTime ?? 0) > 0 || !allowMenu {
                playbackSlider()
            }
        }
        .padding(.top, 6)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.bottom, chatItem.content.text.isEmpty ? 10 : 0)
    }
    
    private func playbackSlider() -> some View {
        ComposeVoiceView.SliderBar(
            length: TimeInterval(duration),
            progress: $playbackTime,
            seek: {
                let time = max(0.0001, $0)
                seek(time)
                playbackTime = time
            })
        .onChange(of: .playing == playbackState || (playbackTime ?? 0) > 0) { show in
            if !show {
                allowMenu = true
            }
        }
    }
}

struct XauXatCodeLockedVoiceView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject var chat: Chat
    let chatItem: ChatItem
    let recordingFile: CIFile?
    @Binding var allowMenu: Bool

    var body: some View {
        Group {
            if let data = loadedData,
               let envelope = try? XauXatCodeLockedEnvelope.decode(data),
               envelope.kind == .audio {
                XauXatUnlockedVoiceView(chat: chat, chatItem: chatItem, envelope: envelope, allowMenu: $allowMenu)
            } else if recordingFile?.loaded == true {
                protectedRow(label: "Protected audio unavailable", icon: "speaker.slash.fill")
            } else {
                Button(action: download) {
                    protectedRow(
                        label: canDownload ? "Download protected audio" : "Protected audio",
                        icon: canDownload ? "arrow.down" : "lock.fill"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canDownload)
            }
        }
        .privacySensitive()
    }

    private var loadedData: Data? {
        guard let source = getLoadedFileSource(recordingFile) else { return nil }
        return try? getFileData(getAppFilePath(source.filePath), source.cryptoArgs)
    }

    private var canDownload: Bool {
        guard let recordingFile else { return false }
        return switch recordingFile.fileStatus {
        case .rcvInvitation, .rcvAborted: true
        default: false
        }
    }

    private func download() {
        guard canDownload, let recordingFile, let user = chatModel.currentUser else { return }
        Task { await receiveFile(user: user, fileId: recordingFile.fileId) }
    }

    private func protectedRow(label: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 36, height: 36)
            Text(label)
                .font(.body.weight(.medium))
            Spacer(minLength: 12)
            Text("--:--")
                .foregroundColor(theme.colors.secondary)
        }
        .foregroundColor(theme.colors.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct XauXatUnlockedVoiceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject var chat: Chat
    let chatItem: ChatItem
    @StateObject private var session: XauXatCodeLockedSession
    @Binding var allowMenu: Bool
    @State private var showUnlock = false
    @State private var audioPlayer: AudioPlayer?
    @State private var playbackState: VoiceMessagePlaybackState = .noPlayback
    @State private var playbackTime: TimeInterval? = 0

    init(chat: Chat, chatItem: ChatItem, envelope: XauXatCodeLockedEnvelope, allowMenu: Binding<Bool>) {
        self.chat = chat
        self.chatItem = chatItem
        _session = StateObject(wrappedValue: XauXatCodeLockedSession(envelope: envelope))
        _allowMenu = allowMenu
    }

    var body: some View {
        Group {
            switch session.state {
            case let .unlocked(payload):
                if payload.kind == .audio, let duration = payload.duration, duration > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            playbackButton(data: payload.body)
                            VoiceMessagePlayerTime(
                                recordingTime: TimeInterval(duration),
                                playbackState: $playbackState,
                                playbackTime: $playbackTime
                            )
                            .foregroundColor(theme.colors.secondary)
                            .frame(width: 50, alignment: .leading)
                            if playbackState != .noPlayback || (playbackTime ?? 0) > 0 {
                                ComposeVoiceView.SliderBar(
                                    length: TimeInterval(duration),
                                    progress: $playbackTime,
                                    seek: seek
                                )
                                .tint(theme.colors.primary)
                            }
                        }
                        if let caption = payload.caption, !caption.isEmpty {
                            Text(caption)
                                .font(.body)
                                .padding(.horizontal, 12)
                        }
                        CIMetaView(chat: chat, chatItem: chatItem, metaColor: theme.colors.secondary)
                            .padding(.leading, 6)
                    }
                    .padding(.vertical, 8)
                } else {
                    protectedRow(label: "Protected audio unavailable", icon: "speaker.slash.fill")
                }
            case .unlocking:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking code")
                }
                .padding(12)
            case .locked, .rejected:
                Button { showUnlock = true } label: {
                    protectedRow(label: "Tap to unlock audio", icon: "lock.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .privacySensitive()
        .sheet(isPresented: $showUnlock) {
            XauXatCodeUnlockView(session: session)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                stopPlayback()
                session.lock()
            }
        }
        .onDisappear {
            stopPlayback()
            session.lock()
        }
    }

    private func protectedRow(label: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 36, height: 36)
            Text(label)
                .font(.body.weight(.medium))
            Spacer(minLength: 12)
            Text("--:--")
                .foregroundColor(theme.colors.secondary)
        }
        .foregroundColor(theme.colors.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func playbackButton(data: Data) -> some View {
        Button {
            switch playbackState {
            case .noPlayback:
                let player = AudioPlayer(
                    onTimer: { playbackTime = $0 },
                    onFinishPlayback: {
                        playbackState = .noPlayback
                        playbackTime = 0
                        allowMenu = true
                    }
                )
                audioPlayer = player
                player.start(data: data)
                playbackState = .playing
                allowMenu = false
            case .playing:
                audioPlayer?.pause()
                playbackState = .paused
                allowMenu = true
            case .paused:
                audioPlayer?.play()
                playbackState = .playing
                allowMenu = false
            }
        } label: {
            Image(systemName: playbackState == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.colors.primary)
        .accessibilityLabel(playbackState == .playing ? "Pause protected audio" : "Play protected audio")
    }

    private func seek(_ time: TimeInterval) {
        let safeTime = max(0.0001, time)
        audioPlayer?.seek(safeTime)
        playbackTime = safeTime
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playbackState = .noPlayback
        playbackTime = 0
        allowMenu = true
    }
}

struct FramedCIVoiceView_Previews: PreviewProvider {
    static var previews: some View {
        let im = ItemsModel.shared
        let sentVoiceMessage: ChatItem = ChatItem(
            chatDir: .directSnd,
            meta: CIMeta.getSample(1, .now, "", .sndSent(sndProgress: .complete), itemEdited: true),
            content: .sndMsgContent(msgContent: .voice(text: "Hello there", duration: 30)),
            quotedItem: nil,
            file: CIFile.getSample(fileStatus: .sndComplete)
        )
        let voiceMessageWithQuote: ChatItem = ChatItem(
            chatDir: .directSnd,
            meta: CIMeta.getSample(1, .now, "", .sndSent(sndProgress: .complete), itemEdited: true),
            content: .sndMsgContent(msgContent: .voice(text: "", duration: 30)),
            quotedItem: CIQuote.getSample(1, .now, "Hi", chatDir: .directRcv),
            file: CIFile.getSample(fileStatus: .sndComplete)
        )
        Group {
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: sentVoiceMessage, scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getVoiceMsgContentSample(text: "Hello there"), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getVoiceMsgContentSample(text: "Hello there", fileStatus: .rcvTransfer(rcvProgress: 7, rcvTotal: 10)), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getVoiceMsgContentSample(text: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: voiceMessageWithQuote, scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
        }
        .environment(\.revealed, false)
        .previewLayout(.fixed(width: 360, height: 360))
    }
}
