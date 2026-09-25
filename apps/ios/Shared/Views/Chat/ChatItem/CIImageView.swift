//
//  CIImageView.swift
//  SimpleX
//
//  Created by JRoberts on 12/04/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/chat-view.md

import SwiftUI
import SimpleXChat

private let xauxatConsumedOneTimePhotosKey = "xauxat.consumedOneTimePhotos"

func xauxatIsOneTimePhoto(_ chatItem: ChatItem) -> Bool {
    xauxatOneTimePhotoPolicy(chatItem) != nil
}

func xauxatOneTimePhotoExportAllowed(_ chatItem: ChatItem) -> Bool {
    chatItem.chatDir.sent || xauxatOneTimePhotoPolicy(chatItem) != .noSave
}

private func xauxatOneTimePhotoConsumed(_ chatItem: ChatItem) -> Bool {
    guard !chatItem.chatDir.sent, let fileName = chatItem.file?.fileName else { return false }
    return Set(UserDefaults.standard.stringArray(forKey: xauxatConsumedOneTimePhotosKey) ?? []).contains(fileName)
}

private func xauxatMarkOneTimePhotoConsumed(_ chatItem: ChatItem) {
    guard let fileName = chatItem.file?.fileName else { return }
    var consumed = Set(UserDefaults.standard.stringArray(forKey: xauxatConsumedOneTimePhotosKey) ?? [])
    consumed.insert(fileName)
    UserDefaults.standard.set(Array(consumed), forKey: xauxatConsumedOneTimePhotosKey)
}

private func xauxatRemoveConsumedPhotoFile(_ chatItem: ChatItem) {
    if let filePath = chatItem.file?.fileSource?.filePath,
       FileManager.default.fileExists(atPath: getAppFilePath(filePath).path) {
        removeFile(filePath)
    }
}

// Spec: spec/client/chat-view.md#CIImageView
struct CIImageView: View {
    private enum OneTimePlaceholderState {
        case sent
        case sentPressToView
        case unopened
        case pressToView
        case consumed

        var icon: String {
            switch self {
            case .sent, .unopened: "1.circle"
            case .sentPressToView, .pressToView: "hand.tap"
            case .consumed: "eye.slash"
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .sent: "One-time photo"
            case .sentPressToView: "Press-to-view photo"
            case .unopened: "Tap to view"
            case .pressToView: "Tap to open"
            case .consumed: "Photo expired"
            }
        }

        var accessibilityLabel: LocalizedStringKey {
            switch self {
            case .sent: "One-time photo sent"
            case .sentPressToView: "Press-to-view photo sent"
            case .unopened: "One-time photo. Tap to view"
            case .pressToView: "Press-to-view photo. Tap to open"
            case .consumed: "One-time photo expired"
            }
        }
    }

    @EnvironmentObject var m: ChatModel
    let chatItem: ChatItem
    let senderProfile: LocalProfile?
    var scrollToItem: ((ChatItem.ID) -> Void)? = nil
    var preview: UIImage?
    let maxWidth: CGFloat
    var imgWidth: CGFloat?
    var smallView: Bool = false
    @Binding var showFullScreenImage: Bool
    @State private var blurred: Bool = UserDefaults.standard.integer(forKey: DEFAULT_PRIVACY_MEDIA_BLUR_RADIUS) > 0
    @State private var oneTimeConsumed = false
    @State private var oneTimeRevealing = false

    private var codeLockedPhoto: Bool {
        guard case let .xauXatImage(text, _, _) = chatItem.content.msgContent else { return false }
        return XauXatCodeLockedEnvelope.isFileWireText(text)
    }

    private var pressToViewPhoto: Bool {
        guard case let .xauXatImage(_, _, privacy) = chatItem.content.msgContent else { return false }
        return privacy.pressToView
    }

    var body: some View {
        let file = chatItem.file
        let sentOneTime = chatItem.chatDir.sent && xauxatIsOneTimePhoto(chatItem)
        let receivedOneTime = !chatItem.chatDir.sent && xauxatIsOneTimePhoto(chatItem)
        let consumed = !oneTimeRevealing && (oneTimeConsumed || xauxatOneTimePhotoConsumed(chatItem))
        VStack(alignment: .center, spacing: 6) {
            if sentOneTime {
                oneTimePlaceholder(state: pressToViewPhoto ? .sentPressToView : .sent)
            } else if codeLockedPhoto {
                codeLockedPhotoView(file: file, receivedOneTime: receivedOneTime, consumed: consumed)
            } else if receivedOneTime, consumed {
                oneTimePlaceholder(state: .consumed)
            } else if receivedOneTime, let uiImage = getLoadedXauXatImage(chatItem) {
                if pressToViewPhoto {
                    oneTimePlaceholder(state: .pressToView)
                        .fullScreenCover(isPresented: $showFullScreenImage, onDismiss: {
                            oneTimeRevealing = false
                        }) {
                            XauXatHoldToViewImage(
                                image: uiImage,
                                caption: xauxatImageCaption,
                                showView: $showFullScreenImage,
                                onReveal: { xauxatMarkOneTimePhotoConsumed(chatItem) },
                                onRelease: consumeOneTimePhoto
                            )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            oneTimeRevealing = true
                            showFullScreenImage = true
                        }
                } else {
                    oneTimePlaceholder(state: .unopened)
                        .fullScreenCover(isPresented: $showFullScreenImage, onDismiss: consumeOneTimePhoto) {
                            FullScreenMediaView(
                                chatItem: chatItem,
                                scrollToItem: nil,
                                image: uiImage,
                                showView: $showFullScreenImage,
                                restrictToCurrentItem: true,
                                allowSave: xauxatOneTimePhotoPolicy(chatItem) == .allowSave,
                                onPresented: { xauxatMarkOneTimePhotoConsumed(chatItem) }
                            )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            oneTimeRevealing = true
                            showFullScreenImage = true
                        }
                }
            } else if let uiImage = getLoadedXauXatImage(chatItem) {
                Group { if smallView { smallViewImageView(uiImage) } else { imageView(uiImage) } }
                .fullScreenCover(isPresented: $showFullScreenImage) {
                    FullScreenMediaView(chatItem: chatItem, scrollToItem: scrollToItem, image: uiImage, showView: $showFullScreenImage)
                }
                .if(!smallView) { view in
                    view.modifier(PrivacyBlur(blurred: $blurred))
                }
                .if(!blurred) { v in
                    v.simultaneousGesture(TapGesture().onEnded { showFullScreenImage = true })
                }
                .onChange(of: m.activeCallViewIsCollapsed) { _ in
                    showFullScreenImage = false
                }
            } else if let preview {
                Group {
                    if receivedOneTime {
                        oneTimePlaceholder(state: .unopened)
                    } else if smallView {
                        smallViewImageView(preview)
                    } else {
                        imageView(preview).modifier(PrivacyBlur(blurred: $blurred))
                    }
                }
                    .simultaneousGesture(TapGesture().onEnded { handleUnloadedImage(file) })
            }
        }
        .onAppear {
            if receivedOneTime && consumed {
                xauxatRemoveConsumedPhotoFile(chatItem)
            }
        }
        .onDisappear {
            // Presenting a one-time photo can make the chat cell temporarily
            // disappear. Do not let that lifecycle event dismiss the cover.
            if !oneTimeRevealing {
                showFullScreenImage = false
            }
        }
    }

    private var xauxatImageCaption: String? {
        guard case let .xauXatImage(text, _, _) = chatItem.content.msgContent,
              !text.isEmpty,
              !XauXatCodeLockedEnvelope.isFileWireText(text)
        else { return nil }
        return text
    }

    @ViewBuilder private func codeLockedPhotoView(file: CIFile?, receivedOneTime: Bool, consumed: Bool) -> some View {
        if receivedOneTime, consumed {
            codeLockedPlaceholder(label: "Photo expired", icon: "eye.slash")
        } else if smallView {
            codeLockedPlaceholder(label: "Protected photo", icon: "lock.fill")
        } else if let data = getLoadedXauXatFileData(chatItem),
                  let envelope = try? XauXatCodeLockedEnvelope.decode(data),
                  envelope.kind == .image {
            XauXatCodeLockedImageView(
                envelope: envelope,
                maxWidth: maxWidth,
                sent: chatItem.chatDir.sent,
                allowExport: xauxatOneTimePhotoExportAllowed(chatItem),
                onReveal: {
                    oneTimeRevealing = true
                    if receivedOneTime { xauxatMarkOneTimePhotoConsumed(chatItem) }
                },
                onConsume: {
                    if receivedOneTime { consumeOneTimePhoto() }
                }
            )
        } else if file?.loaded == true {
            codeLockedPlaceholder(label: "Protected photo unavailable", icon: "eye.slash")
        } else {
            codeLockedPlaceholder(
                label: showDownloadButton(file?.fileStatus) ? "Download protected photo" : "Protected photo",
                icon: showDownloadButton(file?.fileStatus) ? "arrow.down" : "lock.fill"
            )
                .contentShape(Rectangle())
                .onTapGesture { handleUnloadedImage(file) }
        }
    }

    private func consumeOneTimePhoto() {
        xauxatRemoveConsumedPhotoFile(chatItem)
        oneTimeConsumed = true
        oneTimeRevealing = false
    }

    private func oneTimePlaceholder(state: OneTimePlaceholderState) -> some View {
        let width = smallView ? maxWidth : min(maxWidth, 228)
        let height = smallView ? maxWidth : 62
        return ZStack {
            Color.black.opacity(0.88)
            if smallView {
                Image(systemName: state.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: state.icon)
                        .font(.system(size: 24, weight: .regular))
                    Text(state.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.accessibilityLabel))
        .privacySensitive()
    }

    private func codeLockedPlaceholder(label: LocalizedStringKey, icon: String) -> some View {
        ZStack {
            Color.black.opacity(0.92)
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: smallView ? 18 : 25, weight: .medium))
                if !smallView {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundColor(.white)
        }
        .frame(width: maxWidth, height: smallView ? maxWidth : maxWidth * 0.75)
        .clipped()
        .accessibilityLabel(Text(label))
        .privacySensitive()
    }

    private func handleUnloadedImage(_ file: CIFile?) {
        guard let file else { return }
        switch file.fileStatus {
        case .rcvInvitation, .rcvAborted:
            if fileSizeValid(file, senderProfile) {
                Task {
                    if let user = m.currentUser {
                        await receiveFile(user: user, fileId: file.fileId)
                    }
                }
            } else {
                let prettyMaxFileSize = ByteCountFormatter.string(fromByteCount: getMaxFileSize(file.fileProtocol, senderProfile), countStyle: .binary)
                AlertManager.shared.showAlertMsg(
                    title: "Large file!",
                    message: "Your contact sent a file that is larger than currently supported maximum size (\(prettyMaxFileSize))."
                )
            }
        case .rcvAccepted:
            switch file.fileProtocol {
            case .xftp:
                AlertManager.shared.showAlertMsg(title: "Waiting for image", message: "Image will be received when your contact completes uploading it.")
            case .smp:
                AlertManager.shared.showAlertMsg(title: "Waiting for image", message: "Image will be received when your contact is online, please wait or check later!")
            case .local: ()
            }
        case let .rcvError(error): showFileErrorAlert(error)
        case let .rcvWarning(error): showFileErrorAlert(error, temporary: true)
        case let .sndError(error): showFileErrorAlert(error)
        case let .sndWarning(error): showFileErrorAlert(error, temporary: true)
        default: ()
        }
    }

    private func imageView(_ img: UIImage) -> some View {
        let w = img.size.width <= img.size.height ? maxWidth * 0.75 : maxWidth
        return ZStack(alignment: .topTrailing) {
            if img.imageData == nil {
                Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: w * heightRatio(img.size))
                        .clipped()
            } else {
                SwiftyGif(image: img, contentMode: .scaleAspectFill)
                        .frame(width: w, height: w * heightRatio(img.size))
                        .clipped()
            }
            if !blurred || !showDownloadButton(chatItem.file?.fileStatus) {
                loadingIndicator()
            }
        }
    }

    private func smallViewImageView(_ img: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if img.imageData == nil {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: maxWidth, height: maxWidth)
            } else {
                SwiftyGif(image: img, contentMode: .scaleAspectFill)
                    .frame(width: maxWidth, height: maxWidth)
            }
            if chatItem.file?.showStatusIconInSmallView == true {
                loadingIndicator()
            }
        }
    }

    @ViewBuilder private func loadingIndicator() -> some View {
        if let file = chatItem.file {
            switch file.fileStatus {
            case .sndStored:
                switch file.fileProtocol {
                case .xftp: progressView()
                case .smp: EmptyView()
                case .local: EmptyView()
                }
            case .sndTransfer: progressView()
            case .sndComplete: fileIcon("checkmark", 10, 13)
            case .sndCancelled: fileIcon("xmark", 10, 13)
            case .sndError: fileIcon("xmark", 10, 13)
            case .sndWarning: fileIcon("exclamationmark.triangle.fill", 10, 13)
            case .rcvInvitation: fileIcon("arrow.down", 10, 13)
            case .rcvAccepted: fileIcon("ellipsis", 14, 11)
            case .rcvTransfer: progressView()
            case .rcvAborted: fileIcon("exclamationmark.arrow.circlepath", 14, 11)
            case .rcvComplete: EmptyView()
            case .rcvCancelled: fileIcon("xmark", 10, 13)
            case .rcvError: fileIcon("xmark", 10, 13)
            case .rcvWarning: fileIcon("exclamationmark.triangle.fill", 10, 13)
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
            .padding(padding)
    }

    private func progressView() -> some View {
        ProgressView()
            .progressViewStyle(.circular)
            .frame(width: 20, height: 20)
            .tint(.white)
            .padding(8)
    }

    private func showDownloadButton(_ fileStatus: CIFileStatus?) -> Bool {
        switch fileStatus {
        case .rcvInvitation: true
        case .rcvAborted: true
        default: false
        }
    }
}

private struct XauXatCodeLockedImageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: XauXatCodeLockedSession
    @State private var showUnlock = false
    @State private var showPreview = false
    @State private var revealed = false

    let maxWidth: CGFloat
    let sent: Bool
    let allowExport: Bool
    let onReveal: () -> Void
    let onConsume: () -> Void

    init(
        envelope: XauXatCodeLockedEnvelope,
        maxWidth: CGFloat,
        sent: Bool,
        allowExport: Bool,
        onReveal: @escaping () -> Void,
        onConsume: @escaping () -> Void
    ) {
        _session = StateObject(wrappedValue: XauXatCodeLockedSession(envelope: envelope))
        self.maxWidth = maxWidth
        self.sent = sent
        self.allowExport = allowExport
        self.onReveal = onReveal
        self.onConsume = onConsume
    }

    var body: some View {
        Group {
            switch session.state {
            case let .unlocked(payload):
                if payload.kind == .image, let image = decodedImage(payload.body) {
                    VStack(alignment: .leading, spacing: 8) {
                        protectedPlaceholder("Tap to open photo", icon: "arrow.up.left.and.arrow.down.right")
                            .contentShape(Rectangle())
                            .onTapGesture { showPreview = true }
                            .fullScreenCover(isPresented: $showPreview) {
                                XauXatHoldToViewImage(
                                    image: image,
                                    caption: payload.caption,
                                    showView: $showPreview,
                                    onReveal: {
                                        revealed = true
                                        onReveal()
                                    },
                                    onRelease: finishReveal
                                )
                            }
                        if allowExport {
                            HStack(spacing: 20) {
                                Button {
                                    onReveal()
                                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                                    if !sent { onConsume() }
                                } label: {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    onReveal()
                                    showShareSheet(items: [image])
                                    if !sent { onConsume() }
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 10)
                        }
                    }
                } else {
                    protectedPlaceholder("Protected photo unavailable", icon: "eye.slash")
                }
            case .unlocking:
                ZStack {
                    Color.black.opacity(0.92)
                    ProgressView().tint(.white)
                }
                .frame(width: maxWidth, height: maxWidth * 0.75)
            case .locked, .rejected:
                Button { showUnlock = true } label: {
                    protectedPlaceholder("Tap to unlock photo", icon: "lock.fill")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens code entry")
            case .exhausted:
                protectedPlaceholder("No attempts remaining", icon: "lock.slash.fill")
            case .destroyed:
                protectedPlaceholder("Content destroyed", icon: "trash.slash.fill")
            }
        }
        .privacySensitive()
        .sheet(isPresented: $showUnlock) {
            XauXatCodeUnlockView(session: session)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                finishReveal()
                showPreview = false
                session.lock()
            }
        }
        .onDisappear {
            // A full-screen cover can temporarily remove the chat cell from
            // the hierarchy. Keep the unlocked session alive while its
            // protected preview is presented.
            if !showPreview {
                finishReveal()
                session.lock()
            }
        }
    }

    private func protectedPlaceholder(_ label: LocalizedStringKey, icon: String) -> some View {
        ZStack {
            Color.black.opacity(0.92)
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .medium))
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundColor(.white)
        }
        .frame(width: maxWidth, height: maxWidth * 0.75)
        .clipped()
    }

    private func decodedImage(_ data: Data) -> UIImage? {
        let image = UIImage(data: data)
        do {
            try image?.setGifFromData(data, levelOfIntegrity: 1.0)
            return image
        } catch {
            return UIImage(data: data)
        }
    }

    private func finishReveal() {
        guard revealed else { return }
        revealed = false
        if !sent { onConsume() }
    }
}
