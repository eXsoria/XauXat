import Foundation
import SwiftUI
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
#if canImport(SimpleXChat)
import SimpleXChat
#endif

enum XauXatExpressionKind: String, Codable, CaseIterable {
    case sticker, sound
}

struct XauXatExpression: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: XauXatExpressionKind
    let title: String
    let builtin: Bool
    let duration: Int
    var favorite: Bool = false
    var lastUsed: Date? = nil
}

enum XauXatExpressionError: LocalizedError {
    case invalidFile, tooLarge, tooLong, libraryFull, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidFile: return NSLocalizedString("Choose a PNG, JPEG or WebP image, or an M4A, MP3, WAV, AIFF or CAF sound.", comment: "expression import")
        case .tooLarge: return NSLocalizedString("Choose a file smaller than 10 MB.", comment: "expression import")
        case .tooLong: return NSLocalizedString("Soundboard clips must be 15 seconds or shorter.", comment: "expression import")
        case .libraryFull: return NSLocalizedString("This pack is full. Remove an item before importing another.", comment: "expression import")
        case .unavailable: return NSLocalizedString("The local pack could not be opened. Nothing was sent.", comment: "expression library")
        }
    }
}

/// This library has no network dependency. Even titles and favorites are sealed
/// with a device-only key belonging to one profile in one storage scope.
@MainActor
final class XauXatExpressionLibrary: ObservableObject {
    static let maxInputBytes = 10 * 1024 * 1024
    static let maxItems = 100
    static let maxSoundSeconds = 15.0
    @Published private(set) var items: [XauXatExpression] = []
    private let directory: URL
    private let key: SymmetricKey
    private var manifest: URL { directory.appendingPathComponent("pack.sealed") }

    init(directory: URL, key: Data) throws {
        guard key.count == 32, directory.isFileURL else { throw XauXatExpressionError.unavailable }
        self.directory = directory
        self.key = SymmetricKey(data: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.complete])
        try excludeBackup(directory)
        if FileManager.default.fileExists(atPath: manifest.path) {
            let data = try open(Data(contentsOf: manifest), context: "manifest")
            items = try JSONDecoder().decode([XauXatExpression].self, from: data)
            guard items.count <= Self.maxItems, Set(items.map(\.id)).count == items.count,
                  items.allSatisfy({ $0.title.count <= 80 && $0.duration >= 0 && $0.duration <= 15 }) else {
                throw XauXatExpressionError.unavailable
            }
        }
    }

#if canImport(SimpleXChat)
    static func forProfile(_ userID: Int64) throws -> XauXatExpressionLibrary {
        let directory = getAppFilesDirectory().appendingPathComponent("expressions-\(userID)", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("pack.sealed").path)
        guard let key = xauXatExpressionLibraryKey(userID: userID, create: !exists) else {
            throw XauXatExpressionError.unavailable
        }
        return try XauXatExpressionLibrary(directory: directory, key: key)
    }
#endif

    func seedIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: manifest.path) else { return }
        let original = items
        do {
            for emoji in ["👍", "😂", "❤️", "🎉", "👀", "🔥"] {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = false
                let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { _ in
                    let text = emoji as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 190)]
                    let size = text.size(withAttributes: attributes)
                    text.draw(at: CGPoint(x: (256 - size.width) / 2, y: (256 - size.height) / 2), withAttributes: attributes)
                }
                guard let data = image.pngData() else { throw XauXatExpressionError.invalidFile }
                try append(data, kind: .sticker, title: emoji, builtin: true)
            }
            for (title, notes) in [("Pop", [740.0]), ("Ta-da", [523.25, 659.25, 783.99]), ("Boing", [180.0, 360.0, 240.0])] {
                let url = try Self.writeTone(notes)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let (data, duration) = try Self.readSound(url)
                try append(data, kind: .sound, title: title, builtin: true, duration: duration)
            }
            try persist(items)
        } catch {
            for item in items where !original.contains(item) { try? FileManager.default.removeItem(at: assetURL(item)) }
            items = original
            throw error
        }
    }

    /// Import only explicit local files, never URL/playlist references. Rebuild
    /// the media from pixels/PCM rather than retaining source tags or filenames.
    func importFile(_ url: URL, kind: XauXatExpressionKind) async throws {
        guard items.count < Self.maxItems else { throw XauXatExpressionError.libraryFull }
        let normalized = try await Task.detached(priority: .userInitiated) {
            guard url.isFileURL else { throw XauXatExpressionError.invalidFile }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw XauXatExpressionError.invalidFile }
            guard let size = values.fileSize, size > 0, size <= Self.maxInputBytes else { throw XauXatExpressionError.tooLarge }
            let ext = url.pathExtension.lowercased()
            switch kind {
            case .sticker:
                guard ["png", "jpg", "jpeg", "webp"].contains(ext) else { throw XauXatExpressionError.invalidFile }
                let data = try Data(contentsOf: url)
                guard data.count <= Self.maxInputBytes else { throw XauXatExpressionError.tooLarge }
                return (try Self.normalizeSticker(data), 0)
            case .sound:
                guard ["m4a", "mp3", "wav", "aif", "aiff", "caf"].contains(ext) else { throw XauXatExpressionError.invalidFile }
                return try Self.readSound(url)
            }
        }.value
        try Task.checkCancellation()
        // Another import may have completed while this task decoded the file.
        guard items.count < Self.maxItems else { throw XauXatExpressionError.libraryFull }
        try append(normalized.0, kind: kind, title: String(url.deletingPathExtension().lastPathComponent.prefix(80)), duration: normalized.1)
        do { try persist(items) } catch {
            if let item = items.last { try? FileManager.default.removeItem(at: assetURL(item)); items.removeLast() }
            throw error
        }
    }

    func data(for item: XauXatExpression) throws -> Data {
        guard items.contains(where: { $0.id == item.id && $0.kind == item.kind }) else { throw XauXatExpressionError.unavailable }
        return try open(Data(contentsOf: assetURL(item)), context: item.id.uuidString)
    }

    func toggleFavorite(_ item: XauXatExpression) throws {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[i].favorite.toggle()
        try persist(updated)
        items = updated
    }

    func markUsed(_ item: XauXatExpression) throws {
        var updated = items
        guard let i = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[i].lastUsed = Date()
        try persist(updated)
        items = updated
    }

    func remove(_ item: XauXatExpression) throws {
        let updated = items.filter { $0.id != item.id }
        try persist(updated)
        items = updated
        try FileManager.default.removeItem(at: assetURL(item))
    }

    private func append(_ data: Data, kind: XauXatExpressionKind, title: String, builtin: Bool = false, duration: Int = 0) throws {
        let item = XauXatExpression(id: UUID(), kind: kind, title: title, builtin: builtin, duration: duration)
        try write(data, to: assetURL(item), context: item.id.uuidString)
        items.append(item)
    }

    private func assetURL(_ item: XauXatExpression) -> URL {
        directory.appendingPathComponent(item.id.uuidString + ".sealed")
    }

    private func persist(_ items: [XauXatExpression]) throws {
        try write(JSONEncoder().encode(items), to: manifest, context: "manifest")
    }

    private func write(_ data: Data, to url: URL, context: String) throws {
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        guard let bytes = sealed.combined else { throw XauXatExpressionError.unavailable }
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        try excludeBackup(url)
    }

    private func open(_ data: Data, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
    }

    private func excludeBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    nonisolated static func normalizeSticker(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000,
              width * height <= 40_000_000,
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw XauXatExpressionError.invalidFile }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: pixels.width, height: pixels.height)
        let rebuilt = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: pixels).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = rebuilt.pngData() else { throw XauXatExpressionError.invalidFile }
        return png
    }

    /// Reading PCM and encoding a fresh AAC stream drops artwork, tags, extra
    /// tracks and source metadata. Bound decoded frames before allocating.
    nonisolated static func readSound(_ url: URL) throws -> (Data, Int) {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let seconds = Double(input.length) / format.sampleRate
        guard seconds.isFinite, seconds > 0, seconds <= maxSoundSeconds else { throw XauXatExpressionError.tooLong }
        guard format.sampleRate >= 8000, format.sampleRate <= 96000,
              format.channelCount > 0, format.channelCount <= 2,
              input.length <= 1_440_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else {
            throw XauXatExpressionError.invalidFile
        }
        try input.read(into: buffer)
        let output = try temporaryMediaURL("m4a")
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        do {
            let writer = try AVAudioFile(forWriting: output, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 64000
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try writer.write(from: buffer)
            // AVAudioFile closes and finalizes its container at the end of scope.
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: output.path)
        let data = try Data(contentsOf: output)
        guard data.count <= 512 * 1024 else { throw XauXatExpressionError.tooLarge }
        return (data, max(1, Int(ceil(seconds))))
    }

    nonisolated private static func writeTone(_ notes: [Double]) throws -> URL {
        let rate = 44100.0
        let count = Int(rate * 0.20) * notes.count
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            let noteLength = Int(rate * 0.20)
            let local = Double(i % noteLength) / Double(noteLength)
            buffer.floatChannelData![0][i] = Float(sin(2 * .pi * notes[i / noteLength] * Double(i) / rate) * sin(.pi * local) * 0.25)
        }
        let url = try temporaryMediaURL("caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
    }

    nonisolated private static func temporaryMediaURL(_ ext: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.protectionKey: FileProtectionType.complete])
        return directory.appendingPathComponent("audio." + ext)
    }
}
