import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

/// Keyboard-sized tray with local pack shortcuts and search. Stickers send on
/// tap; sounds have separate preview and composer-selection actions.
@MainActor
struct XauXatExpressionsView: View {
    @ObservedObject var library: XauXatExpressionLibrary
    let allowStickers: Bool
    let allowSounds: Bool
    var allowPlayback: Bool = true
    var sending = false
    let close: () -> Void
    let select: (XauXatExpression, Data) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var kind: XauXatExpressionKind = .sticker
    @State private var pack = "all"
    @State private var query = ""
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?
    @State private var player: AVAudioPlayer?
    @State private var previewTask: Task<Void, Never>?
    @State private var playing: UUID?
    @State private var thumbnails: [UUID: UIImage] = [:]

    private var visibleItems: [XauXatExpression] {
        let filtered = library.items.filter {
            $0.kind == kind && (pack == "all" || (pack == "recent" && $0.lastUsed != nil)
                || (pack == "favorites" && $0.favorite) || (pack == "builtin" && $0.builtin)
                || (pack == "mine" && !$0.builtin))
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
        return pack == "recent" ? filtered.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) } : filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        packButton("all", "square.grid.2x2", "All")
                        packButton("recent", "clock", "Recents")
                        packButton("favorites", "star", "Favorites")
                        packButton("builtin", "face.smiling", "XauXat")
                        packButton("mine", "square.stack", "My pack")
                    }
                }
                Button { importing = true } label: { Image(systemName: "plus.circle").font(.title3) }
                    .accessibilityLabel("Import stickers or sounds")
                    .disabled(busy || library.items.count >= XauXatExpressionLibrary.maxItems)
                Button(action: close) { Image(systemName: "chevron.down").font(.body.weight(.semibold)) }
                    .accessibilityLabel("Close stickers and sounds")
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search this device", text: $query)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(8).background(Color.secondary.opacity(0.08)).cornerRadius(10)
            .padding(.horizontal, 12).padding(.vertical, 6)
            if (kind == .sticker && !allowStickers) || (kind == .sound && !allowSounds) {
                Text(kind == .sticker ? "Files and media are disabled in this conversation." : "Voice messages are disabled in this conversation.")
                    .font(.footnote).foregroundColor(.secondary).padding(.horizontal)
            }
            ScrollView {
                if visibleItems.isEmpty {
                    Text("No items here yet. Use + to import your own.")
                        .font(.subheadline).foregroundColor(.secondary).padding()
                }
                LazyVGrid(columns: kind == .sound && dynamicTypeSize.isAccessibilitySize
                          ? [GridItem(.flexible())]
                          : [GridItem(.adaptive(minimum: kind == .sticker ? 76 : 120))], spacing: 12) {
                    ForEach(visibleItems) { item in tile(item) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .accessibilityIdentifier("expression-items")
            if busy { ProgressView("Preparing media…").font(.footnote) }
            Divider()
            HStack(spacing: 24) {
                kindButton(.sticker, "square.on.square", "Stickers")
                kindButton(.sound, "waveform", "Soundboard")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: kind == .sticker ? [.png, .jpeg, .webP] : [.mpeg4Audio, .mp3, .wav, .aiff, .init(filenameExtension: "caf")!],
                      allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                let importKind = kind
                busy = true
                stop()
                importTask = Task {
                    defer { busy = false; refreshThumbnails() }
                    do {
                        for url in urls {
                            try Task.checkCancellation()
                            try await library.importFile(url, kind: importKind)
                        }
                        pack = "mine"
                    } catch is CancellationError { } catch { self.error = error.localizedDescription }
                }
            case let .failure(error): self.error = error.localizedDescription
            }
        }
        .onAppear {
            if !allowStickers && allowSounds { kind = .sound }
            do { try library.seedIfNeeded(); refreshThumbnails() }
            catch { self.error = XauXatExpressionError.unavailable.localizedDescription }
        }
        .onChange(of: kind) { _ in stop() }
        .onChange(of: allowPlayback) { allowed in if !allowed { stop() } }
        .onDisappear { importTask?.cancel(); stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in stop() }
        .alert("Could not prepare media", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func packButton(_ value: String, _ icon: String, _ title: LocalizedStringKey) -> some View {
        Button { pack = value } label: {
            Image(systemName: icon).font(.body)
                .frame(width: 44, height: 36)
                .background(pack == value ? Color.accentColor.opacity(0.14) : .clear)
                .cornerRadius(9)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(pack == value ? .isSelected : [])
    }

    private func kindButton(_ value: XauXatExpressionKind, _ icon: String, _ title: LocalizedStringKey) -> some View {
        Button { kind = value } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 2) {
                        Image(systemName: icon).font(.body)
                        Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label(title, systemImage: icon).font(.subheadline)
                }
            }
            .fontWeight(kind == value ? .semibold : .regular)
            .foregroundColor(kind == value ? .accentColor : .secondary)
            .padding(.vertical, 4)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(kind == value ? .isSelected : [])
    }

    private func tile(_ item: XauXatExpression) -> some View {
        VStack(spacing: 6) {
            Button {
                do { let data = try library.data(for: item); stop(); select(item, data) }
                catch { self.error = XauXatExpressionError.unavailable.localizedDescription }
            } label: {
                Group {
                    if item.kind == .sticker, let image = thumbnails[item.id] {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 72)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                Text("\(item.duration)s").font(.caption).foregroundColor(.secondary)
                            }
                            Image(systemName: "arrow.up.circle.fill").accessibilityHidden(true)
                        }
                        .padding(10).background(Color.secondary.opacity(0.08)).cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.kind == .sticker ? "Send sticker \(item.title)" : "Choose sound \(item.title)")
            .disabled(busy || sending || (item.kind == .sticker ? !allowStickers : !allowSounds))
            .contextMenu {
                Button {
                    do { try library.toggleFavorite(item) } catch { self.error = XauXatExpressionError.unavailable.localizedDescription }
                } label: { Label(item.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") }
                Button(role: .destructive) {
                    do {
                        if playing == item.id { stop() }
                        try library.remove(item)
                        thumbnails[item.id] = nil
                    } catch { self.error = XauXatExpressionError.unavailable.localizedDescription }
                } label: { Label("Remove from pack", systemImage: "trash") }
            }
            if item.kind == .sound {
                Button { preview(item) } label: {
                    Label(playing == item.id && player?.isPlaying == true ? "Stop" : "Preview",
                          systemImage: playing == item.id && player?.isPlaying == true ? "stop.fill" : "play.fill")
                        .font(.caption).padding(.vertical, 6).frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Preview \(item.title)")
                .disabled(!allowPlayback || busy)
            }
        }
    }

    private func refreshThumbnails() {
        thumbnails = Dictionary(uniqueKeysWithValues: library.items.compactMap { item in
            guard item.kind == .sticker, let data = try? library.data(for: item),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 192
                  ] as CFDictionary) else { return nil }
            return (item.id, UIImage(cgImage: pixels))
        })
    }

    private func preview(_ item: XauXatExpression) {
        if playing == item.id && player?.isPlaying == true { stop(); return }
        stop()
        do {
            let data = try library.data(for: item)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data)
            player?.volume = 0.65
            guard player?.play() == true else { throw XauXatExpressionError.invalidFile }
            playing = item.id
            let duration = player?.duration ?? TimeInterval(item.duration)
            previewTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000)) }
                catch { return }
                stop()
            }
        } catch { self.error = XauXatExpressionError.unavailable.localizedDescription; stop() }
    }

    private func stop() {
        previewTask?.cancel()
        previewTask = nil
        player?.stop()
        player = nil
        if playing != nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        playing = nil
    }
}

