import SwiftUI
import CryptoKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

@main
struct ExpressionsHarness: App {
    var body: some Scene { WindowGroup { HarnessView() } }
}

@MainActor
struct HarnessView: View {
    @State private var library: XauXatExpressionLibrary?
    @State private var result = "Checking privacy…"
    @State private var selected = "Nothing sent"
    @State private var show = true
    private let limited = ProcessInfo.processInfo.arguments.contains("--limited")

    var body: some View {
        VStack(spacing: 0) {
            Text("XauXat").font(.headline).padding()
            Divider()
            Text(result).font(.caption).accessibilityIdentifier("validation").padding()
            Spacer()
            HStack { Text("Sounds good! 👀").padding(12).background(Color.secondary.opacity(0.1)).cornerRadius(16); Spacer() }.padding()
            Text(selected).accessibilityIdentifier("selection").padding()
            HStack {
                Image(systemName: "plus")
                Text("Unsent draft stays here").foregroundColor(.secondary)
                Spacer()
                Image(systemName: "face.smiling")
                Image(systemName: "mic")
            }.padding().background(Color.secondary.opacity(0.06))
            if let library, show {
                XauXatExpressionsView(library: library, allowStickers: !limited, allowSounds: true,
                                      allowPlayback: !limited, close: { show = false }) { item, _ in
                    selected = item.kind == .sticker ? "Sticker sent" : "Sound ready to send"
                    try? library.markUsed(item)
                }
                .frame(height: 320)
            }
        }
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility3 : .large)
        .task {
            do {
                result = "Privacy checks passed: \(try await privacyChecks())"
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                library = try XauXatExpressionLibrary(directory: root, key: Data(repeating: 47, count: 32))
            } catch { result = "FAILED: \(error)" }
        }
    }
}

@MainActor
func privacyChecks() async throws -> Int {
    var checks = 0
    func check(_ value: Bool, _ name: String) throws {
        guard value else { throw NSError(domain: name, code: 1) }
        checks += 1
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 19, count: 32)
    let lib = try XauXatExpressionLibrary(directory: root, key: key)
    let permission = AVAudioSession.sharedInstance().recordPermission
    try lib.seedIfNeeded()
    try check(lib.items.count == 9, "seeded pack")
    try lib.seedIfNeeded()
    try check(lib.items.count == 9, "idempotent seed")
    try check(AVAudioSession.sharedInstance().recordPermission == permission, "no microphone request")
    let first = lib.items[0]
    let pixels = try lib.data(for: first)
    try check(UIImage(data: pixels) != nil, "valid sticker")
    let audio = lib.items.first { $0.kind == .sound }!
    let soundURL = root.appendingPathComponent("input.m4a")
    try lib.data(for: audio).write(to: soundURL)
    try check(AVAudioFile(forReading: soundURL).length > 0, "valid encoded sound")
    let taggedAudio = root.appendingPathComponent("tagged.m4a")
    let exporter = AVAssetExportSession(asset: AVURLAsset(url: soundURL), presetName: AVAssetExportPresetPassthrough)!
    exporter.outputURL = taggedAudio
    exporter.outputFileType = .m4a
    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = "PRIVATE_AUDIO_TITLE" as NSString
    exporter.metadata = [title]
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        exporter.exportAsynchronously { continuation.resume() }
    }
    try check(exporter.status == .completed && AVURLAsset(url: taggedAudio).commonMetadata.contains { $0.stringValue == "PRIVATE_AUDIO_TITLE" }, "tagged sound fixture")
    try await lib.importFile(taggedAudio, kind: .sound)
    let cleanAudio = root.appendingPathComponent("clean.m4a")
    try lib.data(for: lib.items.last!).write(to: cleanAudio)
    try check(!AVURLAsset(url: cleanAudio).commonMetadata.contains { $0.stringValue == "PRIVATE_AUDIO_TITLE" }, "audio tags stripped")
    try lib.toggleFavorite(first)
    try lib.markUsed(first)
    let reopened = try XauXatExpressionLibrary(directory: root, key: key)
    try check(reopened.items[0].favorite && reopened.items[0].lastUsed != nil, "favorites and recents survive relaunch")
    let manifest = try Data(contentsOf: root.appendingPathComponent("pack.sealed"))
    try check(manifest.range(of: Data("favorite".utf8)) == nil, "manifest encrypted")
    var wrongKeyRejected = false
    do { _ = try XauXatExpressionLibrary(directory: root, key: Data(repeating: 99, count: 32)) }
    catch { wrongKeyRejected = true }
    try check(wrongKeyRejected, "wrong key rejected")
    let asset = root.appendingPathComponent(first.id.uuidString + ".sealed")
    let sealed = try Data(contentsOf: asset)
    try check(sealed != pixels, "media encrypted")
    var tampered = sealed
    tampered[tampered.count - 1] ^= 1
    try tampered.write(to: asset)
    var tamperRejected = false
    do { _ = try lib.data(for: first) } catch { tamperRejected = true }
    try check(tamperRejected, "modified media rejected")
    try sealed.write(to: asset)
    let secondAsset = root.appendingPathComponent(lib.items[1].id.uuidString + ".sealed")
    let secondOriginal = try Data(contentsOf: secondAsset)
    try sealed.write(to: secondAsset)
    var swapRejected = false
    do { _ = try lib.data(for: lib.items[1]) } catch { swapRejected = true }
    try check(swapRejected, "swapped media rejected")
    try secondOriginal.write(to: secondAsset)
    // An input image carries GPS tags. Its rebuilt PNG must contain only pixels.
    let tagged = NSMutableData()
    let destination = CGImageDestinationCreateWithData(tagged, UTType.jpeg.identifier as CFString, 1, nil)!
    let image = UIImage(data: pixels)!.cgImage!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.72, kCGImagePropertyGPSLongitude: -9.14]] as CFDictionary)
    try check(CGImageDestinationFinalize(destination), "tagged fixture encoded")
    let clean = try XauXatExpressionLibrary.normalizeSticker(tagged as Data)
    let source = CGImageSourceCreateWithData(clean as CFData, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
    try check(props[kCGImagePropertyGPSDictionary] == nil && props[kCGImagePropertyExifDictionary] == nil, "GPS and EXIF stripped")
    let imported = root.appendingPathComponent("PRIVATE_TITLE.png")
    try (tagged as Data).write(to: imported)
    try await lib.importFile(imported, kind: .sticker)
    try check(lib.items.last?.title == "PRIVATE_TITLE", "local import")
    let sealedManifest = try Data(contentsOf: root.appendingPathComponent("pack.sealed"))
    try check(sealedManifest.range(of: Data("PRIVATE_TITLE".utf8)) == nil, "import title encrypted")
    let count = lib.items.count
    var remoteRejected = false
    do { try await lib.importFile(URL(string: "https://example.invalid/sticker.png")!, kind: .sticker) }
    catch { remoteRejected = true }
    try check(remoteRejected && lib.items.count == count, "remote URL rejected without import")
    let oversized = root.appendingPathComponent("large.png")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(XauXatExpressionLibrary.maxInputBytes + 1))
    try handle.close()
    var largeRejected = false
    do { try await lib.importFile(oversized, kind: .sticker) } catch { largeRejected = true }
    try check(largeRejected && lib.items.count == count, "oversized file rejected")
    let cancelled = Task { try await lib.importFile(imported, kind: .sticker) }
    cancelled.cancel()
    var cancellationRejected = false
    do { try await cancelled.value } catch { cancellationRejected = true }
    try check(cancellationRejected && lib.items.count == count, "cancelled import not committed")
    let longURL = root.appendingPathComponent("long.caf")
    do {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128000)!
        buffer.frameLength = 128000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 128000)
        let file = try AVAudioFile(forWriting: longURL, settings: format.settings)
        try file.write(from: buffer)
    }
    var longRejected = false
    do { try await lib.importFile(longURL, kind: .sound) } catch { longRejected = true }
    try check(longRejected && lib.items.count == count, "long sound rejected")
    let other = try XauXatExpressionLibrary(directory: root.appendingPathComponent("other-profile"), key: Data(repeating: 22, count: 32))
    var crossProfileRejected = false
    do { _ = try other.data(for: first) } catch { crossProfileRejected = true }
    try check(crossProfileRejected, "profile isolation")
    try lib.remove(first)
    try check(!FileManager.default.fileExists(atPath: asset.path), "removed media deleted")
    var deletedRejected = false
    do { _ = try lib.data(for: first) } catch { deletedRejected = true }
    try check(deletedRejected, "deleted entry rejected")
    try lib.addStickerToFavorites(UIImage(data: pixels)!)
    let favoritesCount = lib.items.count
    try lib.addStickerToFavorites(UIImage(data: pixels)!)
    try check(lib.items.count == favoritesCount && lib.items.contains(where: { $0.favorite }), "received favorite deduplicated")
    try check(XauXatExpressionLibrary.isStickerFilename("sticker_\(UUID().uuidString).png"), "sticker filename recognized")
    try check(!XauXatExpressionLibrary.isStickerFilename("sticker_not-a-uuid.png") && !XauXatExpressionLibrary.isStickerFilename("../sticker_\(UUID().uuidString).png"), "ordinary filenames not treated as stickers")
    return checks
}
