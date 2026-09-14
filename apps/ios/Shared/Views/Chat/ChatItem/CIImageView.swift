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
    @EnvironmentObject var m: ChatModel
    @EnvironmentObject private var plusEntitlements: XauXatPlusEntitlements
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

    var body: some View {
        let file = chatItem.file
        let receivedOneTime = !chatItem.chatDir.sent && xauxatIsOneTimePhoto(chatItem)
        let consumed = !oneTimeRevealing && (oneTimeConsumed || xauxatOneTimePhotoConsumed(chatItem))
        VStack(alignment: .center, spacing: 6) {
            if codeLockedPhoto {
                codeLockedPhotoView(file: file, receivedOneTime: receivedOneTime, consumed: consumed)
            } else if receivedOneTime, consumed {
                oneTimePlaceholder(image: preview, consumed: true)
            } else if receivedOneTime, let uiImage = getLoadedXauXatImage(chatItem) {
                if plusEntitlements.isAuthorized(for: .pressToPreview) {
                    XauXatPressToPreview(
                        onReveal: {
                            oneTimeRevealing = true
                            xauxatMarkOneTimePhotoConsumed(chatItem)
                        },
                        onHide: {
                            if oneTimeRevealing { consumeOneTimePhoto() }
                        },
                        protectedContent: { imageView(uiImage) },
                        placeholder: { oneTimePlaceholder(image: uiImage, consumed: false, pressToPreview: true) }
                    )
                } else {
                    oneTimePlaceholder(image: uiImage, consumed: false)
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
                        oneTimePlaceholder(image: preview, consumed: false)
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
            showFullScreenImage = false
        }
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

    private func oneTimePlaceholder(image: UIImage?, consumed: Bool, pressToPreview: Bool = false) -> some View {
        let size = image?.size ?? CGSize(width: 4, height: 3)
        let width = smallView ? maxWidth : (size.width <= size.height ? maxWidth * 0.75 : maxWidth)
        let height = smallView ? maxWidth : width * heightRatio(size)
        return ZStack {
            Color.black.opacity(0.88)
            VStack(spacing: 7) {
                Image(systemName: consumed ? "eye.slash" : pressToPreview ? "hand.tap" : "eye")
                    .font(.system(size: smallView ? 18 : 25, weight: .medium))
                if !smallView {
                    Text(consumed ? "Photo expired" : pressToPreview ? "Press and hold to view" : "Tap to view once")
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundColor(.white)
        }
        .frame(width: width, height: height)
        .clipped()
        .accessibilityLabel(
            consumed
            ? "One-time photo expired"
            : pressToPreview ? "One-time photo. Use the reveal action to view for ten seconds" : "One-time photo. Tap to view"
        )
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
                        XauXatPressToPreview(
                            onReveal: {
                                revealed = true
                                onReveal()
                            },
                            onHide: finishReveal,
                            protectedContent: {
                                VStack(alignment: .leading, spacing: 8) {
                                    protectedImage(image)
                                    if let caption = payload.caption, !caption.isEmpty {
                                        Text(caption)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.bottom, 4)
                                    }
                                }
                            },
                            placeholder: { protectedPlaceholder("Press and hold to view", icon: "hand.tap") }
                        )
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
            }
        }
        .privacySensitive()
        .sheet(isPresented: $showUnlock) {
            XauXatCodeUnlockView(session: session)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                finishReveal()
                session.lock()
            }
        }
        .onDisappear {
            finishReveal()
            session.lock()
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

    @ViewBuilder private func protectedImage(_ image: UIImage) -> some View {
        let width = image.size.width <= image.size.height ? maxWidth * 0.75 : maxWidth
        if image.imageData == nil {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: width * heightRatio(image.size))
                .clipped()
        } else {
            SwiftyGif(image: image, contentMode: .scaleAspectFill)
                .frame(width: width, height: width * heightRatio(image.size))
                .clipped()
        }
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
