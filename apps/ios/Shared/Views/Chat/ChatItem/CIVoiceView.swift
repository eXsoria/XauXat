//
//  CIVoiceView.swift
//  SimpleX (iOS)
//
//  Created by JRoberts on 22.11.2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/chat-view.md

import AVFoundation
import AudioToolbox
import SwiftUI
import SimpleXChat

let xauXatVoiceOncePrefix = "xauxat-voice-once-"

func xauXatIsOneTimeVoice(_ item: ChatItem) -> Bool {
    item.content.msgContent?.isVoice == true && item.file?.fileName.hasPrefix(xauXatVoiceOncePrefix) == true
}

struct XauXatOneTimeVoiceView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var chat: Chat
    let item: ChatItem
    @State private var player: AudioPlayer?
    @State private var activeSource: URL?
    @State private var played = false
    @State private var downloading = false

    private var consumedKey: String? {
        guard let user = chatModel.currentUser, let file = item.file else { return nil }
        return "xauxatVoiceOnce.\(xauXatStorageScope()).\(user.userId).\(file.fileName)"
    }

    private var consumed: Bool {
        played || consumedKey.map { UserDefaults.standard.bool(forKey: $0) } == true
    }

    private var isDownloading: Bool {
        switch item.file?.fileStatus {
        case .rcvAccepted, .rcvTransfer: return true
        default: return downloading
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "1.circle").accessibilityHidden(true)
                if item.chatDir.sent {
                    Text("Listen once")
                } else if player != nil {
                    Button("Stop playback", action: stop)
                } else if consumed {
                    Text("Opened")
                } else if let source = getLoadedFileSource(item.file) {
                    Button("Listen once") { play(source) }
                        .disabled(scenePhase != .active || chatModel.activeCall != nil)
                } else if let file = item.file, file.fileStatus == .rcvInvitation || file.fileStatus == .rcvAborted {
                    Button("Download voice message") {
                        guard let user = chatModel.currentUser, !downloading else { return }
                        downloading = true
                        Task {
                            await receiveFile(user: user, fileId: file.fileId)
                            downloading = false
                        }
                    }
                    .disabled(downloading)
                } else {
                    Text("Voice message")
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(minHeight: 36)
            CIMetaView(chat: chat, chatItem: item, metaColor: theme.colors.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .tint(xauXatChampagne(colorScheme))
        .background { chatItemFrameColor(item, theme).modifier(ChatTailPadding()) }
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { if $0 != .active { stop() } }
        .onChange(of: chatModel.currentUser?.userId) { _ in stop() }
        .onChange(of: chatModel.stopPreviousRecPlay) { if $0 != activeSource { stop() } }
    }

    private func play(_ source: CryptoFile) {
        guard !consumed, let key = consumedKey, chatModel.activeCall == nil else { return }
        let path = getAppFilePath(source.filePath)
        do {
            let data = try getFileData(path, source.cryptoArgs)
            let audio = AudioPlayer(onTimer: { _ in }, onFinishPlayback: stop)
            activeSource = path
            chatModel.stopPreviousRecPlay = path
            AudioPlayer.changeAudioSession(true)
            guard audio.start(data: data) else {
                audio.stop()
                stop()
                throw XauXatVoiceMaskError.renderingFailed
            }
            UserDefaults.standard.set(true, forKey: key)
            played = true
            player = audio
            removeFile(path)
        } catch {
            AlertManager.shared.showAlertMsg(title: "Unable to play voice message", message: "Error: \(error.localizedDescription)")
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        if let activeSource, chatModel.stopPreviousRecPlay == activeSource {
            chatModel.stopPreviousRecPlay = nil
        }
        activeSource = nil
    }
}

// Spec: spec/client/chat-view.md#CIVoiceView
struct CIVoiceView: View {
    @ObservedObject var chat: Chat
    @EnvironmentObject private var chatModel: ChatModel
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var theme: AppTheme
    var chatItem: ChatItem
    let recordingFile: CIFile?
    let duration: Int
    @State var audioPlayer: AudioPlayer? = nil
    @State var playbackState: VoiceMessagePlaybackState = .noPlayback
    @State var playbackTime: TimeInterval? = nil

    @Binding var allowMenu: Bool
    var smallViewSize: CGFloat?
    @State private var seek: (TimeInterval) -> Void = { _ in }

    var body: some View {
        Group {
            if smallViewSize != nil {
                HStack(spacing: 10) {
                    player()
                    playerTime()
                        .allowsHitTesting(false)
                    if .playing == playbackState || (playbackTime ?? 0) > 0 || !allowMenu {
                        playbackSlider()
                    }
                }
            } else {
                voiceBubble
            }
        }
        .background {
            if smallViewSize == nil {
                chatItemFrameColor(chatItem, theme).modifier(ChatTailPadding())
            }
        }
    }

    private var voiceBubble: some View {
        let source = getLoadedFileSource(recordingFile)
        let color = xauXatChampagne(colorScheme)
        return HStack(alignment: .top, spacing: 5) {
            senderAvatar(color)
            player()
            VStack(alignment: .trailing, spacing: 0) {
                VoiceMessageWaveform(
                    source: source,
                    duration: TimeInterval(duration),
                    progress: playbackTime ?? 0,
                    color: xauXatWaveformColor(colorScheme),
                    seek: playbackState == .noPlayback ? nil : seekToPosition
                )
                .frame(height: 44)
                voiceBubbleMetadata
            }
            .frame(minWidth: 0, maxWidth: 188)
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var voiceBubbleMetadata: some View {
        if #available(iOS 16, *) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    durationLabel.fixedSize()
                    Spacer(minLength: 0)
                    metaView().fixedSize()
                }
                stackedMetadata
            }
        } else {
            stackedMetadata
        }
    }

    private var stackedMetadata: some View {
        VStack(alignment: .trailing, spacing: 3) {
            durationLabel.frame(maxWidth: .infinity, alignment: .leading)
            metaView()
        }
    }

    private var durationLabel: some View {
        Text(voiceMessageTime(playbackState == .noPlayback ? TimeInterval(duration) : playbackTime ?? 0))
            .font(.caption.monospacedDigit())
            .foregroundColor(theme.colors.secondary)
    }

    private func senderAvatar(_ color: Color) -> some View {
        let image = chatItem.chatDir.sent
            ? (chat.chatInfo.incognito ? nil : chatModel.currentUser?.image)
            : ciSenderProfile(chatItem, chat.chatInfo)?.image
        return ProfileImage(imageStr: image, size: 40, color: color.opacity(0.7), radiusOverride: 50)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
                    .padding(3)
                    .background(chatItemFrameColor(chatItem, theme), in: Circle())
            }
            .frame(height: 44)
            .accessibilityHidden(true)
    }

    private func seekToPosition(_ position: TimeInterval) {
        let time = max(0.0001, position)
        seek(time)
        playbackTime = time
    }

    private func player() -> some View {
        let sizeMultiplier: CGFloat = if let sz = smallViewSize {
            voiceMessageSizeBasedOnSquareSize(sz) / 56
        } else {
            1
        }
        return VoiceMessagePlayer(
            chat: chat,
            chatItem: chatItem,
            recordingFile: recordingFile,
            recordingTime: TimeInterval(duration),
            showBackground: smallViewSize != nil,
            seek: $seek,
            audioPlayer: $audioPlayer,
            playbackState: $playbackState,
            playbackTime: $playbackTime,
            allowMenu: $allowMenu,
            sizeMultiplier: sizeMultiplier,
            buttonSize: smallViewSize == nil ? 44 : 56
        )
    }

    private func playerTime() -> some View {
        VoiceMessagePlayerTime(
            recordingTime: TimeInterval(duration),
            playbackState: $playbackState,
            playbackTime: $playbackTime
        )
        .foregroundColor(theme.colors.secondary)
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
            .tint(xauXatChampagne(colorScheme))
    }

    private func metaView() -> some View {
        CIMetaView(chat: chat, chatItem: chatItem, metaColor: theme.colors.secondary)
    }
}

private struct VoiceMessageWaveform: View {
    let source: CryptoFile?
    let duration: TimeInterval
    let progress: TimeInterval
    let color: Color
    let seek: ((TimeInterval) -> Void)?
    @State private var levels: [Float] = []

    var body: some View {
        ZStack {
            Canvas { context, size in
                let count = 40
                let step = (size.width - 12) / CGFloat(count - 1)
                guard step > 0 else { return }
                let progressFraction = duration > 0 ? min(1, max(0, progress / duration)) : 0
                for index in 0..<count {
                    let level = levels.indices.contains(index) ? CGFloat(levels[index]) : 0
                    let barHeight = 3 + level * 21
                    let width = min(3, step * 0.64)
                    let x = 6 + step * CGFloat(index)
                    let bar = CGRect(x: x - width / 2, y: (size.height - barHeight) / 2, width: width, height: barHeight)
                    let played = Double(index) / Double(count - 1) < progressFraction
                    context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(color.opacity(played ? 1 : 0.75)))
                }
                if source != nil {
                    let x = 6 + (size.width - 12) * progressFraction
                    context.fill(Path(ellipseIn: CGRect(x: x - 5, y: size.height / 2 - 5, width: 10, height: 10)), with: .color(color))
                }
            }
            .accessibilityHidden(true)
            if let seek, duration > 0 {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                            guard geometry.size.width > 12 else { return }
                            let fraction = (gesture.location.x - 6) / (geometry.size.width - 12)
                            seek(duration * min(1, max(0, fraction)))
                        })
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(voiceMessageTime(progress))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: seek(min(duration, progress + 5))
                    case .decrement: seek(max(0, progress - 5))
                    @unknown default: break
                    }
                }
            }
        }
        .task(id: source) {
            levels = []
            guard let source else { return }
            let url = getAppFilePath(source.filePath)
            let worker = Task.detached(priority: .utility) { voiceWaveformLevels(url, source.cryptoArgs) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !Task.isCancelled { levels = result }
        }
    }
}

private func voiceWaveformLevels(_ url: URL, _ cryptoArgs: CryptoFileArgs?) -> [Float] {
    var file: ExtAudioFileRef?
    var encryptedAudioFile: AudioFileID?
    // Encrypted clips are decoded from memory. Keep the bytes alive until both audio handles close.
    var decrypted: NSData?
    defer {
        if let file { ExtAudioFileDispose(file) }
        if let encryptedAudioFile { AudioFileClose(encryptedAudioFile) }
        withExtendedLifetime(decrypted) {}
    }
    if let cryptoArgs {
        guard let data = try? getFileData(url, cryptoArgs) else { return [] }
        let bytes = data as NSData
        decrypted = bytes
        let opened = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(bytes).toOpaque(),
            { client, offset, requested, buffer, actual in
                let bytes = Unmanaged<NSData>.fromOpaque(client).takeUnretainedValue()
                guard offset >= 0, offset < Int64(bytes.length) else {
                    actual.pointee = 0
                    return noErr
                }
                let count = min(Int(requested), bytes.length - Int(offset))
                buffer.copyMemory(from: bytes.bytes.advanced(by: Int(offset)), byteCount: count)
                actual.pointee = UInt32(count)
                return noErr
            },
            nil,
            { Int64(Unmanaged<NSData>.fromOpaque($0).takeUnretainedValue().length) },
            nil,
            0,
            &encryptedAudioFile
        )
        guard opened == noErr, let encryptedAudioFile,
              ExtAudioFileWrapAudioFileID(encryptedAudioFile, false, &file) == noErr else { return [] }
    } else {
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr else { return [] }
    }
    guard let file, let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
          let samples = buffer.floatChannelData?[0] else { return [] }
    var stream = format.streamDescription.pointee
    guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                  UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &stream) == noErr else { return [] }

    let windowSize = 400
    var peaks: [Float] = []
    var peak: Float = 0
    var total = 0
    let limit = Int(MAX_VOICE_MESSAGE_LENGTH * format.sampleRate)
    while !Task.isCancelled && total < limit {
        var count = min(buffer.frameCapacity, AVAudioFrameCount(limit - total))
        buffer.frameLength = count
        guard ExtAudioFileRead(file, &count, buffer.mutableAudioBufferList) == noErr else { return [] }
        if count == 0 { break }
        for index in 0..<Int(count) {
            peak = max(peak, abs(samples[index]))
            total += 1
            if total.isMultiple(of: windowSize) {
                peaks.append(peak)
                peak = 0
            }
        }
    }
    if !total.isMultiple(of: windowSize) { peaks.append(peak) }
    guard !Task.isCancelled, let maximum = peaks.max(), maximum > 0.001 else { return [] }
    return (0..<40).map { index in
        let start = index * peaks.count / 40
        let end = max(start + 1, (index + 1) * peaks.count / 40)
        return sqrt((peaks[start..<end].max() ?? 0) / maximum)
    }
}

struct VoiceMessagePlayerTime: View {
    var recordingTime: TimeInterval
    @Binding var playbackState: VoiceMessagePlaybackState
    @Binding var playbackTime: TimeInterval?

    var body: some View {
        ZStack(alignment: .leading) {
            Text(String("66:66")).foregroundColor(.clear)
            switch playbackState {
            case .noPlayback:
                Text(voiceMessageTime(recordingTime))
            case .playing:
                Text(voiceMessageTime_(playbackTime))
            case .paused:
                Text(voiceMessageTime_(playbackTime))
            }
        }
    }
}

struct VoiceMessagePlayer: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var chat: Chat
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    var chatItem: ChatItem
    var recordingFile: CIFile?
    var recordingTime: TimeInterval
    var showBackground: Bool

    @Binding var seek: (TimeInterval) -> Void
    @Binding var audioPlayer: AudioPlayer?
    @Binding var playbackState: VoiceMessagePlaybackState
    @Binding var playbackTime: TimeInterval?

    @Binding var allowMenu: Bool
    var sizeMultiplier: CGFloat
    var buttonSize: CGFloat = 56

    var body: some View {
        ZStack {
            if xauXatIsOneTimeVoice(chatItem) {
                Image(systemName: "1.circle").accessibilityLabel("Listen once")
            } else if let recordingFile = recordingFile {
                switch recordingFile.fileStatus {
                case .sndStored:
                    if recordingFile.fileProtocol == .local {
                        playbackButton()
                    } else {
                        loadingIcon()
                    }
                case .sndTransfer: loadingIcon()
                case .sndComplete: playbackButton()
                case .sndCancelled: playbackButton()
                case let .sndError(sndFileError):
                    fileStatusIcon("multiply", 14)
                        .simultaneousGesture(TapGesture().onEnded {
                            showFileErrorAlert(sndFileError)
                        })
                case let .sndWarning(sndFileError):
                    fileStatusIcon("exclamationmark.triangle.fill", 16)
                        .simultaneousGesture(TapGesture().onEnded {
                            showFileErrorAlert(sndFileError, temporary: true)
                        })
                case .rcvInvitation: downloadButton(recordingFile, "play.fill")
                case .rcvAccepted: loadingIcon()
                case .rcvTransfer: loadingIcon()
                case .rcvAborted: downloadButton(recordingFile, "exclamationmark.arrow.circlepath")
                case .rcvComplete: playbackButton()
                case .rcvCancelled: playPauseIcon("play.fill", Color(uiColor: .tertiaryLabel))
                case let .rcvError(rcvFileError):
                    fileStatusIcon("multiply", 14)
                        .simultaneousGesture(TapGesture().onEnded {
                            showFileErrorAlert(rcvFileError)
                        })
                case let .rcvWarning(rcvFileError):
                    fileStatusIcon("exclamationmark.triangle.fill", 16)
                        .simultaneousGesture(TapGesture().onEnded {
                            showFileErrorAlert(rcvFileError, temporary: true)
                        })
                case .invalid: playPauseIcon("play.fill", Color(uiColor: .tertiaryLabel))
                }
            } else {
                playPauseIcon("play.fill", Color(uiColor: .tertiaryLabel))
            }
        }
        .onAppear {
            if audioPlayer == nil {
                let small = sizeMultiplier != 1
                audioPlayer = small ? VoiceItemState.smallView[VoiceItemState.id(chat, chatItem)]?.audioPlayer : VoiceItemState.chatView[VoiceItemState.id(chat, chatItem)]?.audioPlayer
                playbackState = (small ? VoiceItemState.smallView[VoiceItemState.id(chat, chatItem)]?.playbackState : VoiceItemState.chatView[VoiceItemState.id(chat, chatItem)]?.playbackState) ?? .noPlayback
                playbackTime = small ? VoiceItemState.smallView[VoiceItemState.id(chat, chatItem)]?.playbackTime : VoiceItemState.chatView[VoiceItemState.id(chat, chatItem)]?.playbackTime
            }
            seek = { to in audioPlayer?.seek(to) }
            let audioPath: URL? = if let recordingSource = getLoadedFileSource(recordingFile) {
                getAppFilePath(recordingSource.filePath)
            } else {
                nil
            }
            let chatId = chatModel.chatId
            let userId = chatModel.currentUser?.userId
            audioPlayer?.onTimer = {
                playbackTime = $0
                notifyStateChange()
                // Manual check here is needed because when this view is not visible, SwiftUI don't react on stopPreviousRecPlay, chatId and current user changes and audio keeps playing when it should stop
                if (audioPath != nil && chatModel.stopPreviousRecPlay != audioPath) || chatModel.chatId != chatId || chatModel.currentUser?.userId != userId {
                    stopPlayback()
                }
            }
            audioPlayer?.onFinishPlayback = {
                playbackState = .noPlayback
                playbackTime = TimeInterval(0)
                notifyStateChange()
            }
            // One voice message was paused, then scrolled far from it, started to play another one, drop to stopped state
            if let audioPath, chatModel.stopPreviousRecPlay != audioPath {
                stopPlayback()
            }
        }
        .onChange(of: chatModel.stopPreviousRecPlay) { it in
            if let recordingFileName = getLoadedFileSource(recordingFile)?.filePath,
               chatModel.stopPreviousRecPlay != getAppFilePath(recordingFileName) {
                stopPlayback()
            }
        }
        .onChange(of: playbackState) { state in
            allowMenu = state == .paused || state == .noPlayback
            // Notify activeContentPreview in ChatPreviewView that playback is finished
            if state == .noPlayback, let recordingFileName = getLoadedFileSource(recordingFile)?.filePath,
               chatModel.stopPreviousRecPlay == getAppFilePath(recordingFileName) {
                chatModel.stopPreviousRecPlay = nil
            }
        }
        .onChange(of: chatModel.chatId) { _ in
            stopPlayback()
        }
        .onDisappear {
            if sizeMultiplier == 1 && chatModel.chatId == nil {
                stopPlayback()
            }
        }
    }

    private func playbackButton() -> some View {
        let icon = switch playbackState {
        case .noPlayback: "play.fill"
        case .playing: "pause.fill"
        case .paused: "play.fill"
        }
        return Button {
            switch playbackState {
            case .noPlayback:
                guard let recordingSource = getLoadedFileSource(recordingFile) else {
                    playbackUnavailable()
                    return
                }
                startPlayback(recordingSource)
            case .playing:
                audioPlayer?.pause()
                playbackState = .paused
                notifyStateChange()
            case .paused:
                guard audioPlayer?.play() == true else {
                    stopPlayback()
                    playbackUnavailable()
                    return
                }
                playbackState = .playing
                notifyStateChange()
            }
        } label: {
            playPauseIcon(icon, xauXatChampagne(colorScheme))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackState == .playing ? "Pause voice message" : "Play voice message")
    }

    private func playbackUnavailable() {
        AlertManager.shared.showAlertMsg(title: "Unable to play voice message", message: "The audio file is missing, incomplete, or could not be opened.")
    }

    private func playPauseIcon(_ image: String, _ color: Color/* = .accentColor*/) -> some View {
        ZStack {
            Image(systemName: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20 * sizeMultiplier, height: 20 * sizeMultiplier)
                .foregroundColor(color)
                .padding(.leading, image == "play.fill" ? 4 : 0)
                .frame(width: buttonSize * sizeMultiplier, height: buttonSize * sizeMultiplier)
                .background(showBackground ? chatItemFrameColor(chatItem, theme) : .clear)
                .clipShape(Circle())
            if showBackground && recordingTime > 0 {
                ProgressCircle(length: recordingTime, progress: $playbackTime, color: xauXatChampagne(colorScheme))
                    .frame(width: 53 * sizeMultiplier, height: 53 * sizeMultiplier) // this + ProgressCircle lineWidth = background circle diameter
            }
        }
    }

    private func downloadButton(_ recordingFile: CIFile, _ icon: String) -> some View {
        playPauseIcon(icon, xauXatChampagne(colorScheme))
            .simultaneousGesture(TapGesture().onEnded {
                Task {
                    if let user = chatModel.currentUser {
                        await receiveFile(user: user, fileId: recordingFile.fileId)
                    }
                }
            })
    }

    func notifyStateChange() {
        if sizeMultiplier != 1 {
            VoiceItemState.smallView[VoiceItemState.id(chat, chatItem)] = VoiceItemState(audioPlayer: audioPlayer, playbackState: playbackState, playbackTime: playbackTime)
        } else {
            VoiceItemState.chatView[VoiceItemState.id(chat, chatItem)] = VoiceItemState(audioPlayer: audioPlayer, playbackState: playbackState, playbackTime: playbackTime)
        }
    }

    private struct ProgressCircle: View {
        var length: TimeInterval
        @Binding var progress: TimeInterval?
        let color: Color

        var body: some View {
            Circle()
                .trim(from: 0, to: ((progress ?? TimeInterval(0)) / length))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 3)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear, value: progress)
        }
    }

    private func fileStatusIcon(_ image: String, _ size: CGFloat) -> some View {
        Image(systemName: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size * sizeMultiplier, height: size * sizeMultiplier)
            .foregroundColor(Color(uiColor: .tertiaryLabel))
            .frame(width: buttonSize * sizeMultiplier, height: buttonSize * sizeMultiplier)
            .background(showBackground ? chatItemFrameColor(chatItem, theme) : .clear)
            .clipShape(Circle())
    }

    private func loadingIcon() -> some View {
        ProgressView()
            .frame(width: 30 * sizeMultiplier, height: 30 * sizeMultiplier)
            .frame(width: buttonSize * sizeMultiplier, height: buttonSize * sizeMultiplier)
            .background(showBackground ? chatItemFrameColor(chatItem, theme) : .clear)
            .clipShape(Circle())
    }

    private func startPlayback(_ recordingSource: CryptoFile) {
        let audioPath = getAppFilePath(recordingSource.filePath)
        let chatId = chatModel.chatId
        let userId = chatModel.currentUser?.userId
        chatModel.stopPreviousRecPlay = audioPath
        audioPlayer = AudioPlayer(
            onTimer: {
                playbackTime = $0
                notifyStateChange()
                // Manual check here is needed because when this view is not visible, SwiftUI don't react on stopPreviousRecPlay, chatId and current user changes and audio keeps playing when it should stop
                if chatModel.stopPreviousRecPlay != audioPath || chatModel.chatId != chatId || chatModel.currentUser?.userId != userId {
                    stopPlayback()
                }
            },
            onFinishPlayback: {
                playbackState = .noPlayback
                playbackTime = TimeInterval(0)
                notifyStateChange()
            }
        )
        let minimumDuration = AudioPlayer.minimumVoiceMessageDuration(recordingTime)
        guard audioPlayer?.start(fileSource: recordingSource, at: playbackTime, minimumDuration: minimumDuration) == true else {
            stopPlayback()
            if chatModel.stopPreviousRecPlay == audioPath { chatModel.stopPreviousRecPlay = nil }
            playbackUnavailable()
            return
        }
        playbackState = .playing
        notifyStateChange()
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        playbackState = .noPlayback
        playbackTime = TimeInterval(0)
        notifyStateChange()
    }
}

@inline(__always)
func voiceMessageSizeBasedOnSquareSize(_ squareSize: CGFloat) -> CGFloat {
    let squareToCircleRatio = 0.935
    return squareSize + squareSize * (1 - squareToCircleRatio)
}

class VoiceItemState {
    var audioPlayer: AudioPlayer?
    var playbackState: VoiceMessagePlaybackState
    var playbackTime: TimeInterval?

    init(audioPlayer: AudioPlayer? = nil, playbackState: VoiceMessagePlaybackState, playbackTime: TimeInterval? = nil) {
        self.audioPlayer = audioPlayer
        self.playbackState = playbackState
        self.playbackTime = playbackTime
    }

    @inline(__always)
    static func id(_ chat: Chat, _ chatItem: ChatItem) -> String {
        "\(chat.id) \(chatItem.id)"
    }

    @inline(__always)
    static func id(_ chatInfo: ChatInfo, _ chatItem: ChatItem) -> String {
        "\(chatInfo.id) \(chatItem.id)"
    }

    static func stopVoiceInSmallView(_ chatInfo: ChatInfo, _ chatItem: ChatItem) {
        let id = id(chatInfo, chatItem)
        if let item = smallView[id] {
            item.audioPlayer?.stop()
            ChatModel.shared.stopPreviousRecPlay = nil
        }
    }

    static func stopVoiceInChatView(_ chatInfo: ChatInfo, _ chatItem: ChatItem) {
        let id = id(chatInfo, chatItem)
        if let item = chatView[id] {
            item.audioPlayer?.stop()
            ChatModel.shared.stopPreviousRecPlay = nil
        }
    }

    static var smallView: [String: VoiceItemState] = [:]
    static var chatView: [String: VoiceItemState] = [:]
}

struct CIVoiceView_Previews: PreviewProvider {
    static var previews: some View {
        let im = ItemsModel.shared
        let sentVoiceMessage: ChatItem = ChatItem(
            chatDir: .directSnd,
            meta: CIMeta.getSample(1, .now, "", .sndSent(sndProgress: .complete), itemEdited: true),
            content: .sndMsgContent(msgContent: .voice(text: "", duration: 30)),
            quotedItem: nil,
            file: CIFile.getSample(fileStatus: .sndComplete)
        )
        let voiceMessageWtFile = ChatItem(
            chatDir: .directRcv,
            meta: CIMeta.getSample(1, .now, "", .rcvRead),
            content: .rcvMsgContent(msgContent: .voice(text: "", duration: 30)),
            quotedItem: nil,
            file: nil
        )
        Group {
            CIVoiceView(
                chat: Chat.sampleData,
                chatItem: ChatItem.getVoiceMsgContentSample(),
                recordingFile: CIFile.getSample(fileName: "voice.m4a", fileSize: 65536, fileStatus: .rcvComplete),
                duration: 30,
                allowMenu: Binding.constant(true)
            )
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: sentVoiceMessage, scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil), allowMenu: .constant(true))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getVoiceMsgContentSample(), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil), allowMenu: .constant(true))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getVoiceMsgContentSample(fileStatus: .rcvTransfer(rcvProgress: 7, rcvTotal: 10)), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil), allowMenu: .constant(true))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: voiceMessageWtFile, scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil), allowMenu: .constant(true))
        }
        .environmentObject(ChatModel.shared)
        .previewLayout(.fixed(width: 360, height: 360))
    }
}
