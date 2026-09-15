//
//  CIVideoView.swift
//  SimpleX
//
//  Created by Avently on 30/03/2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/chat-view.md

import SwiftUI
import AVKit
import SimpleXChat
import Combine

// Spec: spec/client/chat-view.md#CIVideoView
struct CIVideoView: View {
    @EnvironmentObject var m: ChatModel
    private let chatItem: ChatItem
    private let senderProfile: LocalProfile?
    private let preview: UIImage?
    @State private var duration: Int
    @State private var progress: Int = 0
    @State private var videoPlaying: Bool = false
    private let maxWidth: CGFloat
    private var videoWidth: CGFloat?
    private let smallView: Bool
    @State private var player: AVPlayer?
    @State private var fullPlayer: AVPlayer?
    @State private var url: URL?
    @State private var urlDecrypted: URL?
    @State private var decryptionInProgress: Bool = false
    @Binding private var showFullScreenPlayer: Bool
    @State private var timeObserver: Any? = nil
    @State private var fullScreenTimeObserver: Any? = nil
    @State private var publisher: AnyCancellable? = nil
    private var sizeMultiplier: CGFloat { smallView ? 0.38 : 1 }
    @State private var blurred: Bool = UserDefaults.standard.integer(forKey: DEFAULT_PRIVACY_MEDIA_BLUR_RADIUS) > 0

    init(chatItem: ChatItem, senderProfile: LocalProfile?, preview: UIImage?, duration: Int, maxWidth: CGFloat, videoWidth: CGFloat?, smallView: Bool = false, showFullscreenPlayer: Binding<Bool>) {
        self.chatItem = chatItem
        self.senderProfile = senderProfile
        self.preview = preview
        self._duration = State(initialValue: duration)
        self.maxWidth = maxWidth
        self.videoWidth = videoWidth
        self.smallView = smallView
        self._showFullScreenPlayer = showFullscreenPlayer
    }

    private var codeLockedVideo: Bool {
        xauXatIsCodeLockedFile(chatItem.content.text, kind: .video)
    }

    @ViewBuilder
    var body: some View {
        if codeLockedVideo {
            XauXatCodeLockedVideoView(
                chatItem: chatItem,
                senderProfile: senderProfile,
                preview: preview,
                maxWidth: maxWidth,
                smallView: smallView
            )
        } else {
            standardVideoBody
        }
    }

    private var standardVideoBody: some View {
        let file = chatItem.file
        return ZStack(alignment: smallView ? .topLeading : .center) {
            ZStack(alignment: .topLeading) {
                if let file, let preview {
                    if let urlDecrypted {
                        if smallView {
                            smallVideoView(urlDecrypted, file, preview)
                        } else if let player {
                            videoView(player, urlDecrypted, file, preview, duration)
                        }
                    } else if file.loaded {
                        if smallView {
                            smallVideoViewEncrypted(file, preview)
                        } else {
                            videoViewEncrypted(file, preview, duration)
                        }
                    } else {
                        Group { if smallView { smallViewImageView(preview, file) } else { imageView(preview) } }
                            .simultaneousGesture(TapGesture().onEnded {
                                switch file.fileStatus {
                                case .rcvInvitation, .rcvAborted:
                                    receiveFileIfValidSize(file: file, receiveFile: receiveFile)
                                case .rcvAccepted:
                                    switch file.fileProtocol {
                                    case .xftp:
                                        AlertManager.shared.showAlertMsg(
                                            title: "Waiting for video",
                                            message: "Video will be received when your contact completes uploading it."
                                        )
                                    case .smp:
                                        AlertManager.shared.showAlertMsg(
                                            title: "Waiting for video",
                                            message: "Video will be received when your contact is online, please wait or check later!"
                                        )
                                    case .local: ()
                                    }
                                case .rcvTransfer: () // ?
                                case .rcvComplete: () // ?
                                case .rcvCancelled: () // TODO
                                default: ()
                                }
                            })
                    }
                }
                if !smallView {
                    durationProgress()
                }
            }
            if !blurred, let file, showDownloadButton(file.fileStatus) {
                if !smallView || !file.showStatusIconInSmallView {
                    playPauseIcon("play.fill")
                        .simultaneousGesture(TapGesture().onEnded {
                            receiveFileIfValidSize(file: file, receiveFile: receiveFile)
                        })
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreenPlayer) {
            if let decrypted = urlDecrypted {
                fullScreenPlayer(decrypted)
            }
        }
        .onAppear {
            setupPlayer(chatItem.file)
        }
        .onChange(of: chatItem.file) { file in
            // ChatItem can be changed in small view on chat list screen
            setupPlayer(file)
        }
        .onDisappear {
            showFullScreenPlayer = false
        }
    }

    private func setupPlayer(_ file: CIFile?) {
        let newUrl = getLoadedVideo(file)
        if newUrl == url {
            return
        }
        url = nil
        urlDecrypted = nil
        player = nil
        fullPlayer = nil
        if let newUrl {
            let decrypted = file?.fileSource?.cryptoArgs == nil ? newUrl : file?.fileSource?.decryptedGet()
            urlDecrypted = decrypted
            if let decrypted = decrypted {
                player = VideoPlayerView.getOrCreatePlayer(decrypted, false)
                fullPlayer = AVPlayer(url: decrypted)
            }
            url = newUrl
        }
    }

    private func showDownloadButton(_ fileStatus: CIFileStatus?) -> Bool {
        switch fileStatus {
        case .rcvInvitation: true
        case .rcvAborted: true
        default: false
        }
    }

    private func videoViewEncrypted(_ file: CIFile, _ defaultPreview: UIImage, _ duration: Int) -> some View {
        return ZStack(alignment: .topTrailing) {
            ZStack(alignment: .center) {
                let canBePlayed = !chatItem.chatDir.sent || file.fileStatus == CIFileStatus.sndComplete || (file.fileStatus == .sndStored && file.fileProtocol == .local)
                imageView(defaultPreview)
                .simultaneousGesture(TapGesture().onEnded {
                    decrypt(file: file) {
                        showFullScreenPlayer = urlDecrypted != nil
                    }
                })
                .onChange(of: m.activeCallViewIsCollapsed) { _ in
                    showFullScreenPlayer = false
                }
                if !blurred {
                    if !decryptionInProgress {
                        playPauseIcon(canBePlayed ? "play.fill" : "play.slash")
                            .simultaneousGesture(TapGesture().onEnded {
                                decrypt(file: file) {
                                    if urlDecrypted != nil {
                                        videoPlaying = true
                                        player?.play()
                                    }
                                }
                            })
                            .disabled(!canBePlayed)
                    } else {
                        videoDecryptionProgress()
                    }
                }
            }
        }
    }

    private func videoView(_ player: AVPlayer, _ url: URL, _ file: CIFile, _ preview: UIImage, _ duration: Int) -> some View {
        let w = preview.size.width <= preview.size.height ? maxWidth * 0.75 : maxWidth
        return ZStack(alignment: .topTrailing) {
            ZStack(alignment: .center) {
                let canBePlayed = !chatItem.chatDir.sent || file.fileStatus == CIFileStatus.sndComplete || (file.fileStatus == .sndStored && file.fileProtocol == .local)
                VideoPlayerView(player: player, url: url, showControls: false)
                .frame(width: w, height: w * heightRatio(preview.size))
                .clipped()
                .onChange(of: m.stopPreviousRecPlay) { playingUrl in
                    if playingUrl != url {
                        player.pause()
                        videoPlaying = false
                    }
                }
                .modifier(PrivacyBlur(enabled: !videoPlaying, blurred: $blurred))
                .if(!blurred) { v in
                    v.simultaneousGesture(TapGesture().onEnded {
                        switch player.timeControlStatus {
                        case .playing:
                            player.pause()
                            videoPlaying = false
                        case .paused:
                            if canBePlayed {
                                showFullScreenPlayer = true
                            }
                        default: ()
                        }
                    })
                }
                .onChange(of: m.activeCallViewIsCollapsed) { _ in
                    showFullScreenPlayer = false
                }
                if !videoPlaying && !blurred {
                    playPauseIcon(canBePlayed ? "play.fill" : "play.slash")
                        .simultaneousGesture(TapGesture().onEnded {
                            m.stopPreviousRecPlay = url
                            player.play()
                        })
                        .disabled(!canBePlayed)
                }
            }
            fileStatusIcon()
        }
        .onAppear {
            addObserver(player, url)
        }
        .onDisappear {
            removeObserver()
            player.pause()
            videoPlaying = false
        }
    }

    private func smallVideoViewEncrypted(_ file: CIFile, _ preview: UIImage) -> some View {
        return ZStack(alignment: .topLeading) {
            let canBePlayed = !chatItem.chatDir.sent || file.fileStatus == CIFileStatus.sndComplete || (file.fileStatus == .sndStored && file.fileProtocol == .local)
            smallViewImageView(preview, file)
                .onTapGesture { // this is shown in chat list, where onTapGesture works
                    decrypt(file: file) {
                        showFullScreenPlayer = urlDecrypted != nil
                    }
                }
                .onChange(of: m.activeCallViewIsCollapsed) { _ in
                    showFullScreenPlayer = false
                }
            if file.showStatusIconInSmallView {
                // Show nothing
            } else if !decryptionInProgress {
                playPauseIcon(canBePlayed ? "play.fill" : "play.slash")
            } else {
                videoDecryptionProgress()
            }
        }
    }

    private func smallVideoView(_ url: URL, _ file: CIFile, _ preview: UIImage) -> some View {
        return ZStack(alignment: .topLeading) {
            smallViewImageView(preview, file)
                .onTapGesture { // this is shown in chat list, where onTapGesture works
                    showFullScreenPlayer = true
                }
                .onChange(of: m.activeCallViewIsCollapsed) { _ in
                    showFullScreenPlayer = false
                }

            if !file.showStatusIconInSmallView {
                playPauseIcon("play.fill")
            }
        }
    }


    private func playPauseIcon(_ image: String, _ color: Color = .white) -> some View {
        Image(systemName: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: smallView ? 12 * sizeMultiplier * 1.6 : 12, height: smallView ? 12 * sizeMultiplier * 1.6 : 12)
        .foregroundColor(color)
        .padding(.leading, smallView ? 0 : 4)
        .frame(width: 40 * sizeMultiplier, height: 40 * sizeMultiplier)
        .background(Color.black.opacity(0.35))
        .clipShape(Circle())
    }

    private func videoDecryptionProgress(_ color: Color = .white) -> some View {
        ProgressView()
            .progressViewStyle(.circular)
            .frame(width: smallView ? 12 * sizeMultiplier : 12, height: smallView ? 12 * sizeMultiplier : 12)
            .tint(color)
            .frame(width: smallView ? 40 * sizeMultiplier * 0.9 : 40, height: smallView ? 40 * sizeMultiplier * 0.9 : 40)
            .background(Color.black.opacity(0.35))
            .clipShape(Circle())
    }

    private var fileSizeString: String {
        if let file = chatItem.file, !videoPlaying {
            "  " + ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .binary)
        } else {
            ""
        }
    }

    private func durationProgress() -> some View {
        Text((durationText(videoPlaying ? progress : duration)) + fileSizeString)
            .invertedForegroundStyle()
            .font(.caption)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
    }

    private func imageView(_ img: UIImage) -> some View {
        let w = img.size.width <= img.size.height ? maxWidth * 0.75 : maxWidth
        return ZStack(alignment: .topTrailing) {
            Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: w, height: w * heightRatio(img.size))
            .clipped()
            .modifier(PrivacyBlur(blurred: $blurred))
            if !blurred || !showDownloadButton(chatItem.file?.fileStatus) {
                fileStatusIcon()
            }
        }
    }

    private func smallViewImageView(_ img: UIImage, _ file: CIFile) -> some View {
        ZStack(alignment: .center) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: maxWidth, height: maxWidth)
            if file.showStatusIconInSmallView {
                fileStatusIcon()
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func fileStatusIcon() -> some View {
        if let file = chatItem.file {
            switch file.fileStatus {
            case .sndStored:
                switch file.fileProtocol {
                case .xftp: progressView()
                case .smp: EmptyView()
                case .local: EmptyView()
                }
            case let .sndTransfer(sndProgress, sndTotal):
                switch file.fileProtocol {
                case .xftp: progressCircle(sndProgress, sndTotal)
                case .smp: progressView()
                case .local: EmptyView()
                }
            case .sndComplete: fileIcon("checkmark", 10, 13)
            case .sndCancelled: fileIcon("xmark", 10, 13)
            case let .sndError(sndFileError):
                fileIcon("xmark", 10, 13)
                    .simultaneousGesture(TapGesture().onEnded {
                        showFileErrorAlert(sndFileError)
                    })
            case let .sndWarning(sndFileError):
                fileIcon("exclamationmark.triangle.fill", 10, 13)
                    .simultaneousGesture(TapGesture().onEnded {
                        showFileErrorAlert(sndFileError, temporary: true)
                    })
            case .rcvInvitation: fileIcon("arrow.down", 10, 13)
            case .rcvAccepted: fileIcon("ellipsis", 14, 11)
            case let .rcvTransfer(rcvProgress, rcvTotal):
                if file.fileProtocol == .xftp && rcvProgress < rcvTotal {
                    progressCircle(rcvProgress, rcvTotal)
                } else {
                    progressView()
                }
            case .rcvAborted: fileIcon("exclamationmark.arrow.circlepath", 14, 11)
            case .rcvComplete: EmptyView()
            case .rcvCancelled: fileIcon("xmark", 10, 13)
            case let .rcvError(rcvFileError):
                fileIcon("xmark", 10, 13)
                    .simultaneousGesture(TapGesture().onEnded {
                        showFileErrorAlert(rcvFileError)
                    })
            case let .rcvWarning(rcvFileError):
                fileIcon("exclamationmark.triangle.fill", 10, 13)
                    .simultaneousGesture(TapGesture().onEnded {
                        showFileErrorAlert(rcvFileError, temporary: true)
                    })
            case .invalid: fileIcon("questionmark", 10, 13)
            }
        }
    }

    private func fileIcon(_ icon: String, _ size: CGFloat, _ padding: CGFloat) -> some View {
        Image(systemName: icon)
            .resizable()
            .invertedForegroundStyle()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .padding(smallView ? 0 : padding)
    }

    private func progressView() -> some View {
        ProgressView()
        .progressViewStyle(.circular)
        .frame(width: 16, height: 16)
        .tint(.white)
        .padding(smallView ? 0 : 11)
    }

    private func progressCircle(_ progress: Int64, _ total: Int64) -> some View {
        Circle()
        .trim(from: 0, to: Double(progress) / Double(total))
        .stroke(style: StrokeStyle(lineWidth: 2))
        .invertedForegroundStyle()
        .rotationEffect(.degrees(-90))
        .frame(width: 16, height: 16)
        .padding([.trailing, .top], smallView ? 0 : 11)
    }

    // TODO encrypt: where file size is checked?
    private func receiveFileIfValidSize(file: CIFile, receiveFile: @escaping (User, Int64, Bool, Bool) async -> Void) {
        if fileSizeValid(file, senderProfile) {
            Task {
                if let user = m.currentUser {
                    await receiveFile(user, file.fileId, false, false)
                }
            }
        } else {
            let prettyMaxFileSize = ByteCountFormatter.string(fromByteCount: getMaxFileSize(file.fileProtocol, senderProfile), countStyle: .binary)
            AlertManager.shared.showAlertMsg(
                title: "Large file!",
                message: "Your contact sent a file that is larger than currently supported maximum size (\(prettyMaxFileSize))."
            )
        }
    }

    private func fullScreenPlayer(_ url: URL) -> some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            VideoPlayer(player: fullPlayer)
            .overlay(alignment: .topLeading, content: {
                Button(action: { showFullScreenPlayer = false }, // this is used in full screen player, Button works here
                    label: {
                        Image(systemName: "multiply")
                        .resizable()
                        .tint(.white)
                        .frame(width: 15, height: 15)
                        .padding(.leading, 15)
                        .padding(.top, 13)
                    }
                )
            })
            .gesture(
                DragGesture(minimumDistance: 80)
                .onChanged { gesture in
                    let t = gesture.translation
                    let w = abs(t.width)
                    if t.height > 60 && t.height > w * 2 {
                        showFullScreenPlayer = false
                    }
                }
            )
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    // Prevent feedback loop - setting `ChatModel`s property causes `onAppear` to be called on iOS17+
                    if m.stopPreviousRecPlay != url { m.stopPreviousRecPlay = url }
                    if let player = fullPlayer {
                        player.play()
                        var played = false
                        publisher = player.publisher(for: \.timeControlStatus).sink { status in
                            if played || status == .playing {
                                AppDelegate.keepScreenOn(status == .playing)
                                AudioPlayer.changeAudioSession(status == .playing)
                            }
                            played = status == .playing
                        }
                        fullScreenTimeObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
                            player.seek(to: CMTime.zero)
                            player.play()
                        }
                    }
                }
            }
            .onDisappear {
                if let fullScreenTimeObserver = fullScreenTimeObserver {
                    NotificationCenter.default.removeObserver(fullScreenTimeObserver)
                }
                fullScreenTimeObserver = nil
                fullPlayer?.pause()
                fullPlayer?.seek(to: CMTime.zero)
                publisher?.cancel()
            }
        }
    }

    private func decrypt(file: CIFile, completed: (() -> Void)? = nil) {
        if decryptionInProgress { return }
        decryptionInProgress = true
        Task {
            urlDecrypted = await file.fileSource?.decryptedGetOrCreate(&ChatModel.shared.filesToDelete)
            await MainActor.run {
                if let decrypted = urlDecrypted {
                    if !smallView {
                        player = VideoPlayerView.getOrCreatePlayer(decrypted, false)
                    }
                    fullPlayer = AVPlayer(url: decrypted)
                }
                decryptionInProgress = false
                completed?()
            }
        }
    }

    private func addObserver(_ player: AVPlayer, _ url: URL) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.01, preferredTimescale: CMTimeScale(NSEC_PER_SEC)), queue: .main) { time in
            if let item = player.currentItem {
                let dur = CMTimeGetSeconds(item.duration)
                if !dur.isInfinite && !dur.isNaN {
                    duration = Int(dur)
                }
                progress = Int(CMTimeGetSeconds(player.currentTime()))
                // `if` prevents showing Play button while the playback seeks to start and then plays
                if player.currentTime() != player.currentItem?.duration && player.currentTime() != .zero {
                    videoPlaying = player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
        }
    }

    private func removeObserver() {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}

private enum XauXatCodeLockedVideoLoadState {
    case idle
    case loading
    case loaded(XauXatCodeLockedEnvelope)
    case invalid
}

private struct XauXatCodeLockedVideoView: View {
    @EnvironmentObject private var chatModel: ChatModel
    let chatItem: ChatItem
    let senderProfile: LocalProfile?
    let preview: UIImage?
    let maxWidth: CGFloat
    let smallView: Bool
    @State private var loadState: XauXatCodeLockedVideoLoadState = .idle

    private var file: CIFile? { chatItem.file }
    private var loadedSource: CryptoFile? { getLoadedFileSource(file) }
    private var sourceKey: String? { loadedSource?.filePath }

    var body: some View {
        Group {
            if smallView {
                protectedPoster(label: nil, icon: "lock.fill")
                    .allowsHitTesting(false)
            } else if file?.loaded == true {
                switch loadState {
                case let .loaded(envelope):
                    XauXatUnlockedVideoView(
                        envelope: envelope,
                        preview: preview,
                        maxWidth: maxWidth
                    )
                case .invalid:
                    protectedPoster(label: "Protected video unavailable", icon: "video.slash.fill")
                case .idle, .loading:
                    protectedPoster(label: "Loading protected video", icon: "lock.fill")
                        .overlay(alignment: .topTrailing) {
                            ProgressView()
                                .tint(.white)
                                .padding(12)
                        }
                }
            } else {
                Button(action: download) {
                    protectedPoster(
                        label: canDownload ? "Download protected video" : "Protected video",
                        icon: canDownload ? "arrow.down" : "lock.fill"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canDownload)
            }
        }
        .privacySensitive()
        .task(id: sourceKey) {
            await loadEnvelope()
        }
    }

    private var canDownload: Bool {
        guard let file else { return false }
        return switch file.fileStatus {
        case .rcvInvitation, .rcvAborted: true
        default: false
        }
    }

    private func download() {
        guard canDownload, let file, let user = chatModel.currentUser else { return }
        guard fileSizeValid(file, senderProfile) else {
            let maximum = ByteCountFormatter.string(
                fromByteCount: getMaxFileSize(file.fileProtocol, senderProfile),
                countStyle: .binary
            )
            AlertManager.shared.showAlertMsg(
                title: "Large file!",
                message: "Your contact sent a file that is larger than currently supported maximum size (\(maximum))."
            )
            return
        }
        Task { await receiveFile(user: user, fileId: file.fileId) }
    }

    @MainActor
    private func loadEnvelope() async {
        guard !smallView, let source = loadedSource else {
            loadState = .idle
            return
        }
        loadState = .loading
        let envelope = await Task.detached(priority: .userInitiated) {
            guard let data = try? getFileData(getAppFilePath(source.filePath), source.cryptoArgs),
                  let envelope = try? XauXatCodeLockedEnvelope.decode(data),
                  envelope.kind == .video else { return nil as XauXatCodeLockedEnvelope? }
            return envelope
        }.value
        guard !Task.isCancelled else { return }
        loadState = envelope.map(XauXatCodeLockedVideoLoadState.loaded) ?? .invalid
    }

    private func protectedPoster(label: LocalizedStringKey?, icon: String) -> some View {
        let height = smallView ? maxWidth : maxWidth * 9 / 16
        return ZStack {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: smallView ? 18 : 28, weight: .semibold))
                if let label, !smallView {
                    Text(label)
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundColor(.white)
            .padding(16)
        }
        .frame(width: maxWidth, height: height)
        .clipped()
        .contentShape(Rectangle())
    }
}

private struct XauXatUnlockedVideoView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: XauXatCodeLockedSession
    let preview: UIImage?
    let maxWidth: CGFloat
    @State private var showUnlock = false
    @State private var player: AVPlayer?
    @State private var clearURL: URL?
    @State private var revealOperation = UUID()

    init(envelope: XauXatCodeLockedEnvelope, preview: UIImage?, maxWidth: CGFloat) {
        _session = StateObject(wrappedValue: XauXatCodeLockedSession(envelope: envelope))
        self.preview = preview
        self.maxWidth = maxWidth
    }

    var body: some View {
        Group {
            switch session.state {
            case let .unlocked(payload):
                if payload.kind == .video {
                    XauXatPressToPreview(
                        onReveal: { reveal(payload) },
                        onHide: removeClearVideo,
                        protectedContent: { revealedVideo(payload) },
                        placeholder: {
                            protectedPoster(label: "Press and hold to view", icon: "hand.tap.fill")
                        }
                    )
                } else {
                    protectedPoster(label: "Protected video unavailable", icon: "video.slash.fill")
                }
            case .unlocking:
                protectedPoster(label: "Checking code", icon: "lock.fill")
                    .overlay(alignment: .topTrailing) {
                        ProgressView()
                            .tint(.white)
                            .padding(12)
                    }
            case .locked, .rejected:
                Button { showUnlock = true } label: {
                    protectedPoster(label: "Tap to unlock video", icon: "lock.fill")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens code entry")
            }
        }
        .privacySensitive()
        .sheet(isPresented: $showUnlock) {
            XauXatCodeUnlockView(session: session)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                removeClearVideo()
                session.lock()
            }
        }
        .onDisappear {
            removeClearVideo()
            session.lock()
        }
    }

    @ViewBuilder
    private func revealedVideo(_ payload: XauXatCodeLockedPayload) -> some View {
        if let player, let clearURL {
            VStack(alignment: .leading, spacing: 8) {
                VideoPlayerView(player: player, url: clearURL, showControls: false)
                    .frame(width: maxWidth, height: maxWidth * 9 / 16)
                    .clipped()
                if let caption = payload.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.body)
                        .padding(.horizontal, 12)
                }
            }
        } else {
            protectedPoster(label: "Preparing protected video", icon: "lock.open.fill")
                .overlay(alignment: .topTrailing) {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                }
        }
    }

    private func protectedPoster(label: LocalizedStringKey, icon: String) -> some View {
        ZStack {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                Text(label)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.white)
            .padding(16)
        }
        .frame(width: maxWidth, height: maxWidth * 9 / 16)
        .clipped()
        .contentShape(Rectangle())
    }

    private func reveal(_ payload: XauXatCodeLockedPayload) {
        guard player == nil, clearURL == nil else {
            player?.play()
            return
        }
        let operation = UUID()
        revealOperation = operation
        Task {
            let url: URL? = await Task.detached(priority: .userInitiated) { () -> URL? in
                let directory = getTempFilesDirectory()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = xauXatProtectedVideoTempURL()
                    try payload.body.write(to: url, options: [.atomic, .completeFileProtection])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    return url
                } catch {
                    logger.error("Unable to prepare protected XauXat video: \(error.localizedDescription)")
                    return nil
                }
            }.value
            guard let url else { return }
            guard revealOperation == operation else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            ChatModel.shared.filesToDelete.insert(url)
            clearURL = url
            let videoPlayer = AVPlayer(url: url)
            player = videoPlayer
            videoPlayer.play()
        }
    }

    private func removeClearVideo() {
        revealOperation = UUID()
        player?.pause()
        player?.seek(to: .zero)
        player = nil
        if let clearURL {
            ChatModel.shared.filesToDelete.remove(clearURL)
            try? FileManager.default.removeItem(at: clearURL)
        }
        clearURL = nil
    }
}
