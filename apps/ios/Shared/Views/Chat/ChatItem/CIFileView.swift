//
//  CIFileView.swift
//  SimpleX
//
//  Created by JRoberts on 28/04/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/client/chat-view.md

import SwiftUI
import SimpleXChat
import QuickLook
import UniformTypeIdentifiers

// Spec: spec/client/chat-view.md#CIFileView
struct CIFileView: View {
    @EnvironmentObject var m: ChatModel
    @EnvironmentObject var theme: AppTheme
    @Environment(\.showTimestamp) var showTimestamp: Bool
    @AppStorage(DEFAULT_SHOW_SENT_VIA_RPOXY) private var showSentViaProxy = false
    @AppStorage(DEFAULT_PRIVACY_SHOW_SIGNATURE) private var showSignature = true
    @AppStorage(DEFAULT_PRIVACY_SHOW_FILE_ENCRYPTION) private var showFileEncryption = true
    @ObservedObject var chat: Chat
    let file: CIFile?
    let meta: CIMeta
    let senderProfile: LocalProfile?
    var smallViewSize: CGFloat?
    let contentText: String

    init(
        chat: Chat,
        file: CIFile?,
        meta: CIMeta,
        senderProfile: LocalProfile?,
        smallViewSize: CGFloat? = nil,
        contentText: String = ""
    ) {
        self.chat = chat
        self.file = file
        self.meta = meta
        self.senderProfile = senderProfile
        self.smallViewSize = smallViewSize
        self.contentText = contentText
    }

    var body: some View {
        if xauXatIsCodeLockedFile(contentText, kind: .file) {
            XauXatCodeLockedFileView(
                chat: chat,
                file: file,
                meta: meta,
                senderProfile: senderProfile,
                smallViewSize: smallViewSize
            )
        } else if smallViewSize != nil {
            fileIndicator()
            .simultaneousGesture(TapGesture().onEnded(fileAction))
        } else {
            // reserve exact space for the overlaid meta (timestamp + all icons), rendered transparently - matches MsgContentView
            let encrypted: Bool? = if let fileSource = file?.fileSource { fileSource.cryptoArgs != nil } else { nil }
            let metaReserve = Text(verbatim: "   ") + ciMetaText(meta, chatTTL: chat.chatInfo.timedMessagesTTL, encrypted: encrypted, colorMode: .transparent, showViaProxy: showSentViaProxy, showTimesamp: showTimestamp, signedFileVerified: file?.loaded, showSignature: showSignature, showFileEncryption: showFileEncryption)
            HStack(alignment: .bottom, spacing: 6) {
                fileIndicator()
                    .padding(.top, 5)
                    .padding(.bottom, 3)
                if let file = file {
                    let prettyFileSize = ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .binary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.fileName)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                            .foregroundColor(theme.colors.onBackground)
                        (Text(prettyFileSize) + metaReserve)
                            .font(.caption)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                            .foregroundColor(theme.colors.secondary)
                    }
                } else {
                    metaReserve.font(.caption)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .simultaneousGesture(TapGesture().onEnded(fileAction))
            .disabled(!itemInteractive)
        }
    }

    @inline(__always)
    private var itemInteractive: Bool {
        if let file = file {
            switch (file.fileStatus) {
            case .sndStored: return file.fileProtocol == .local
            case .sndTransfer: return false
            case .sndComplete: return true
            case .sndCancelled: return false
            case .sndError: return true
            case .sndWarning: return true
            case .rcvInvitation: return true
            case .rcvAccepted: return true
            case .rcvTransfer: return false
            case .rcvAborted: return true
            case .rcvComplete: return true
            case .rcvCancelled: return false
            case .rcvError: return true
            case .rcvWarning: return true
            case .invalid: return false
            }
        }
        return false
    }

    private func fileAction() {
        logger.debug("CIFileView fileAction")
        if let file = file {
            switch (file.fileStatus) {
            case .rcvInvitation, .rcvAborted:
                if fileSizeValid(file, senderProfile) {
                    Task {
                        logger.debug("CIFileView fileAction - in .rcvInvitation, .rcvAborted, in Task")
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
                    AlertManager.shared.showAlertMsg(
                        title: "Waiting for file",
                        message: "File will be received when your contact completes uploading it."
                    )
                case .smp:
                    AlertManager.shared.showAlertMsg(
                        title: "Waiting for file",
                        message: "File will be received when your contact is online, please wait or check later!"
                    )
                case .local: ()
                }
            case .rcvComplete:
                logger.debug("CIFileView fileAction - in .rcvComplete")
                if let fileSource = getLoadedFileSource(file) {
                    saveCryptoFile(fileSource)
                }
            case let .rcvError(rcvFileError):
                logger.debug("CIFileView fileAction - in .rcvError")
                showFileErrorAlert(rcvFileError)
            case let .rcvWarning(rcvFileError):
                logger.debug("CIFileView fileAction - in .rcvWarning")
                showFileErrorAlert(rcvFileError, temporary: true)
            case .sndStored:
                logger.debug("CIFileView fileAction - in .sndStored")
                if file.fileProtocol == .local, let fileSource = getLoadedFileSource(file) {
                    saveCryptoFile(fileSource)
                }
            case .sndComplete:
                logger.debug("CIFileView fileAction - in .sndComplete")
                if let fileSource = getLoadedFileSource(file) {
                    saveCryptoFile(fileSource)
                }
            case let .sndError(sndFileError):
                logger.debug("CIFileView fileAction - in .sndError")
                showFileErrorAlert(sndFileError)
            case let .sndWarning(sndFileError):
                logger.debug("CIFileView fileAction - in .sndWarning")
                showFileErrorAlert(sndFileError, temporary: true)
            default: break
            }
        }
    }

    @ViewBuilder private func fileIndicator() -> some View {
        if let file = file {
            switch file.fileStatus {
            case .sndStored:
                switch file.fileProtocol {
                case .xftp: progressView()
                case .smp: fileIcon("doc.fill")
                case .local: fileIcon("doc.fill")
                }
            case let .sndTransfer(sndProgress, sndTotal):
                switch file.fileProtocol {
                case .xftp: progressCircle(sndProgress, sndTotal)
                case .smp: progressView()
                case .local: EmptyView()
                }
            case .sndComplete: fileIcon("doc.fill", innerIcon: "checkmark", innerIconSize: 10)
            case .sndCancelled: fileIcon("doc.fill", innerIcon: "xmark", innerIconSize: 10)
            case .sndError: fileIcon("doc.fill", innerIcon: "xmark", innerIconSize: 10)
            case .sndWarning: fileIcon("doc.fill", innerIcon: "exclamationmark.triangle.fill", innerIconSize: 10)
            case .rcvInvitation:
                if fileSizeValid(file, senderProfile) {
                    fileIcon("arrow.down.doc.fill", color: theme.colors.primary)
                } else {
                    fileIcon("doc.fill", color: .orange, innerIcon: "exclamationmark", innerIconSize: 12)
                }
            case .rcvAccepted: fileIcon("doc.fill", innerIcon: "ellipsis", innerIconSize: 12)
            case let .rcvTransfer(rcvProgress, rcvTotal):
                if file.fileProtocol == .xftp && rcvProgress < rcvTotal {
                    progressCircle(rcvProgress, rcvTotal)
                } else {
                    progressView()
                }
            case .rcvAborted:
                fileIcon("doc.fill", color: theme.colors.primary, innerIcon: "exclamationmark.arrow.circlepath", innerIconSize: 12)
            case .rcvComplete: fileIcon("doc.fill")
            case .rcvCancelled: fileIcon("doc.fill", innerIcon: "xmark", innerIconSize: 10)
            case .rcvError: fileIcon("doc.fill", innerIcon: "xmark", innerIconSize: 10)
            case .rcvWarning: fileIcon("doc.fill", innerIcon: "exclamationmark.triangle.fill", innerIconSize: 10)
            case .invalid: fileIcon("doc.fill", innerIcon: "questionmark", innerIconSize: 10)
            }
        } else {
            fileIcon("doc.fill")
        }
    }

    private func fileIcon(_ icon: String, color: Color = Color(uiColor: .tertiaryLabel), innerIcon: String? = nil, innerIconSize: CGFloat? = nil) -> some View {
        let size = smallViewSize ?? 30
        return ZStack(alignment: .center) {
            Image(systemName: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(color)
            if let innerIcon = innerIcon,
               let innerIconSize = innerIconSize, (smallViewSize == nil || file?.showStatusIconInSmallView == true) {
                Image(systemName: innerIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 16)
                    .frame(width: innerIconSize, height: innerIconSize)
                    .foregroundColor(.white)
                    .padding(.top, size / 2.5)
            }
        }
    }

    private func progressView() -> some View {
        ProgressView().frame(width: 30, height: 30)
    }

    private func progressCircle(_ progress: Int64, _ total: Int64) -> some View {
        Circle()
            .trim(from: 0, to: Double(progress) / Double(total))
            .stroke(
                Color(uiColor: .tertiaryLabel),
                style: StrokeStyle(lineWidth: 3)
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 30)
    }
}

private enum XauXatCodeLockedFileLoadState {
    case idle
    case loading
    case loaded(XauXatCodeLockedEnvelope)
    case invalid
}

private struct XauXatCodeLockedFileView: View {
    @EnvironmentObject private var chatModel: ChatModel
    @ObservedObject var chat: Chat
    let file: CIFile?
    let meta: CIMeta
    let senderProfile: LocalProfile?
    let smallViewSize: CGFloat?
    @State private var loadState: XauXatCodeLockedFileLoadState = .idle

    private var loadedSource: CryptoFile? { getLoadedFileSource(file) }
    private var sourceKey: String? { loadedSource?.filePath }

    var body: some View {
        Group {
            if let size = smallViewSize {
                Image(systemName: "lock.doc.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
                    .accessibilityLabel("Protected file")
            } else if file?.loaded == true {
                switch loadState {
                case let .loaded(envelope):
                    XauXatUnlockedFileView(chat: chat, meta: meta, envelope: envelope)
                case .invalid:
                    protectedRow(
                        title: Text("Protected file unavailable"),
                        detail: Text("The encrypted file could not be opened"),
                        icon: "doc.badge.ellipsis"
                    )
                case .idle, .loading:
                    protectedRow(
                        title: Text("Loading protected file"),
                        detail: Text("Please wait"),
                        icon: "lock.doc.fill",
                        loading: true
                    )
                }
            } else {
                Button(action: download) {
                    protectedRow(
                        title: Text(canDownload ? "Download protected file" : "Protected file"),
                        detail: Text(canDownload ? "Code required after download" : "Waiting for file"),
                        icon: canDownload ? "arrow.down.doc.fill" : "lock.doc.fill"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canDownload)
            }
        }
        .privacySensitive()
        .task(id: sourceKey) { await loadEnvelope() }
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
        guard smallViewSize == nil, let source = loadedSource else {
            loadState = .idle
            return
        }
        loadState = .loading
        let envelope = await Task.detached(priority: .userInitiated) {
            guard let data = try? getFileData(getAppFilePath(source.filePath), source.cryptoArgs),
                  let envelope = try? XauXatCodeLockedEnvelope.decode(data),
                  envelope.kind == .file else { return nil as XauXatCodeLockedEnvelope? }
            return envelope
        }.value
        guard !Task.isCancelled else { return }
        loadState = envelope.map(XauXatCodeLockedFileLoadState.loaded) ?? .invalid
    }

    private func protectedRow(title: Text, detail: Text, icon: String, loading: Bool = false) -> some View {
        XauXatProtectedFileRow(
            chat: chat,
            meta: meta,
            title: title,
            detail: detail,
            icon: icon,
            loading: loading
        )
    }
}

private struct XauXatUnlockedFileView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var chat: Chat
    let meta: CIMeta
    @StateObject private var session: XauXatCodeLockedSession
    @State private var showUnlock = false
    @State private var showPreview = false
    @State private var preparingPreview = false
    @State private var clearURL: URL?
    @State private var previewOperation = UUID()

    init(chat: Chat, meta: CIMeta, envelope: XauXatCodeLockedEnvelope) {
        self.chat = chat
        self.meta = meta
        _session = StateObject(wrappedValue: XauXatCodeLockedSession(envelope: envelope))
    }

    var body: some View {
        Group {
            switch session.state {
            case let .unlocked(payload):
                if payload.kind == .file {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { preparePreview(payload) } label: {
                            XauXatProtectedFileRow(
                                chat: chat,
                                meta: meta,
                                title: Text(verbatim: displayName(payload)),
                                detail: Text("Tap to preview · \(formattedSize(payload.body.count))"),
                                icon: "doc.fill",
                                loading: preparingPreview
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(preparingPreview)
                        .accessibilityHint("Opens a protected preview without sharing controls")

                        if let caption = payload.caption, !caption.isEmpty {
                            Text(caption)
                                .font(.body)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                    }
                } else {
                    unavailableRow
                }
            case .unlocking:
                XauXatProtectedFileRow(
                    chat: chat,
                    meta: meta,
                    title: Text("Checking code"),
                    detail: Text("Protected file"),
                    icon: "lock.doc.fill",
                    loading: true
                )
            case .locked, .rejected:
                Button { showUnlock = true } label: {
                    XauXatProtectedFileRow(
                        chat: chat,
                        meta: meta,
                        title: Text("Protected file"),
                        detail: Text("Tap to enter code"),
                        icon: "lock.doc.fill"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens code entry")
            }
        }
        .privacySensitive()
        .sheet(isPresented: $showUnlock) {
            XauXatCodeUnlockView(session: session)
        }
        .sheet(isPresented: $showPreview, onDismiss: removeClearFile) {
            if let clearURL {
                XauXatProtectedFilePreview(url: clearURL) {
                    showPreview = false
                    removeClearFile()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                showPreview = false
                removeClearFile()
                session.lock()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            if UIScreen.main.isCaptured {
                showPreview = false
                removeClearFile()
                session.lock()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            showPreview = false
            removeClearFile()
            session.lock()
        }
        .onDisappear {
            showPreview = false
            removeClearFile()
            session.lock()
        }
    }

    private var unavailableRow: some View {
        XauXatProtectedFileRow(
            chat: chat,
            meta: meta,
            title: Text("Protected file unavailable"),
            detail: Text("The encrypted content is invalid"),
            icon: "doc.badge.ellipsis"
        )
    }

    private func displayName(_ payload: XauXatCodeLockedPayload) -> String {
        guard let fileName = payload.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileName.isEmpty else { return NSLocalizedString("Document", comment: "protected file fallback name") }
        let lastComponent = URL(fileURLWithPath: fileName).lastPathComponent
        return lastComponent.isEmpty ? NSLocalizedString("Document", comment: "protected file fallback name") : lastComponent
    }

    private func formattedSize(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary)
    }

    private func preparePreview(_ payload: XauXatCodeLockedPayload) {
        guard !preparingPreview, clearURL == nil else { return }
        preparingPreview = true
        let operation = UUID()
        previewOperation = operation
        let fileExtension = preferredExtension(payload)
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                let directory = getTempFilesDirectory()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = xauXatProtectedFileTempURL(fileExtension: fileExtension)
                    try payload.body.write(to: url, options: [.atomic, .completeFileProtection])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    return url
                } catch {
                    logger.error("Unable to prepare protected XauXat file: \(error.localizedDescription)")
                    return nil
                }
            }.value
            preparingPreview = false
            guard let url else {
                AlertManager.shared.showAlertMsg(
                    title: "Could not preview file",
                    message: "The protected file could not be prepared."
                )
                return
            }
            guard previewOperation == operation else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            ChatModel.shared.filesToDelete.insert(url)
            clearURL = url
            showPreview = true
        }
    }

    private func preferredExtension(_ payload: XauXatCodeLockedPayload) -> String? {
        if let fileName = payload.fileName {
            let fileExtension = URL(fileURLWithPath: fileName).pathExtension
            if !fileExtension.isEmpty { return fileExtension }
        }
        if let mimeType = payload.mimeType {
            return UTType(mimeType: mimeType)?.preferredFilenameExtension
        }
        return nil
    }

    private func removeClearFile() {
        previewOperation = UUID()
        preparingPreview = false
        if let clearURL {
            ChatModel.shared.filesToDelete.remove(clearURL)
            try? FileManager.default.removeItem(at: clearURL)
        }
        clearURL = nil
    }
}

private struct XauXatProtectedFileRow: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage(DEFAULT_SHOW_SENT_VIA_RPOXY) private var showSentViaProxy = false
    @Environment(\.showTimestamp) private var showTimestamp: Bool
    @ObservedObject var chat: Chat
    let meta: CIMeta
    let title: Text
    let detail: Text
    let icon: String
    var loading: Bool = false

    var body: some View {
        let metaReserve = Text(verbatim: "   ") + ciMetaText(
            meta,
            chatTTL: chat.chatInfo.timedMessagesTTL,
            encrypted: true,
            colorMode: .transparent,
            showViaProxy: showSentViaProxy,
            showTimesamp: showTimestamp
        )
        HStack(alignment: .bottom, spacing: 8) {
            ZStack {
                Image(systemName: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .lineLimit(1)
                    .foregroundColor(theme.colors.onBackground)
                (detail + metaReserve)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundColor(theme.colors.secondary)
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 8)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(minWidth: 220, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct XauXatProtectedFilePreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let url: URL
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Protected preview")
                    .font(.headline)
                Spacer()
                Button("Close", action: close)
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 54)

            XauXatQuickLookPreview(url: url)
        }
        .privacySensitive()
        .modifier(XauXatAppSwitcherProtection())
        .onChange(of: scenePhase) { phase in
            if phase != .active { close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            if UIScreen.main.isCaptured { close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            close()
        }
        .onDisappear(perform: onClose)
    }

    private func close() {
        onClose()
        dismiss()
    }
}

private struct XauXatQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = XauXatReadOnlyPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        func previewController(
            _ controller: QLPreviewController,
            editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .disabled
        }
    }
}

private final class XauXatReadOnlyPreviewController: QLPreviewController {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        removeExportControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        removeExportControls()
    }

    private func removeExportControls() {
        navigationItem.rightBarButtonItem = nil
        navigationItem.rightBarButtonItems = []
        toolbarItems = []
        navigationController?.setToolbarHidden(true, animated: false)
    }
}

func fileSizeValid(_ file: CIFile?, _ senderProfile: LocalProfile?) -> Bool {
    if let file = file {
        return file.fileSize <= getMaxFileSize(file.fileProtocol, senderProfile)
    }
    return false
}

func saveCryptoFile(_ fileSource: CryptoFile) {
    if let cfArgs = fileSource.cryptoArgs {
        let url = getAppFilePath(fileSource.filePath)
        let tempUrl = getTempFilesDirectory().appendingPathComponent(fileSource.filePath)
        Task {
            do {
                try decryptCryptoFile(fromPath: url.path, cryptoArgs: cfArgs, toPath: tempUrl.path)
                await MainActor.run {
                    showShareSheet(items: [tempUrl]) {
                        removeFile(tempUrl)
                    }
                }
            } catch {
                await MainActor.run {
                    AlertManager.shared.showAlertMsg(title: "Error decrypting file", message: "Error: \(error.localizedDescription)")
                }
            }
        }
    } else {
        let url = getAppFilePath(fileSource.filePath)
        showShareSheet(items: [url])
    }
}

func showFileErrorAlert(_ err: FileError, temporary: Bool = false) {
    let title: String = if temporary {
        NSLocalizedString("Temporary file error", comment: "file error alert title")
    } else {
        NSLocalizedString("File error", comment: "file error alert title")
    }
    if let btn = err.moreInfoButton {
        showAlert(title, message: err.errorInfo) {
            [
                okAlertAction,
                UIAlertAction(title: NSLocalizedString("How it works", comment: "alert button"), style: .default, handler: { _ in
                    UIApplication.shared.open(contentModerationPostLink)
                })
            ]
        }
    } else {
        showAlert(title, message: err.errorInfo)
    }
}

struct CIFileView_Previews: PreviewProvider {
    static var previews: some View {
        let im = ItemsModel.shared
        let sentFile: ChatItem = ChatItem(
            chatDir: .directSnd,
            meta: CIMeta.getSample(1, .now, "", .sndSent(sndProgress: .complete), itemEdited: true),
            content: .sndMsgContent(msgContent: .file("")),
            quotedItem: nil,
            file: CIFile.getSample(fileStatus: .sndComplete)
        )
        let fileChatItemWtFile = ChatItem(
            chatDir: .directRcv,
            meta: CIMeta.getSample(1, .now, "", .rcvRead),
            content: .rcvMsgContent(msgContent: .file("")),
            quotedItem: nil,
            file: nil
        )
        Group {
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: sentFile, scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(fileName: "some_long_file_name_here", fileStatus: .rcvInvitation), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(fileStatus: .rcvAccepted), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(fileStatus: .rcvTransfer(rcvProgress: 7, rcvTotal: 10)), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(fileStatus: .rcvCancelled), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(fileSize: 1_000_000_000, fileStatus: .rcvInvitation), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(text: "Hello there", fileStatus: .rcvInvitation), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: ChatItem.getFileMsgContentSample(text: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.", fileStatus: .rcvInvitation), scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
            ChatItemView(chat: Chat.sampleData, im: im, chatItem: fileChatItemWtFile, scrollToItem: { _ in }, scrollToItemId: Binding.constant(nil))
        }
        .environment(\.revealed, false)
        .previewLayout(.fixed(width: 360, height: 360))
    }
}
