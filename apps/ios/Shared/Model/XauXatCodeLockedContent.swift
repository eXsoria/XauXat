import Combine
import CommonCrypto
import CryptoKit
import Foundation
import SimpleXChat

enum XauXatCodeLockedContentKind: String, Codable, CaseIterable {
    case text
    case image
    case audio
    case video
    case file
}

struct XauXatCodeLockedPayload: Codable, Equatable {
    let kind: XauXatCodeLockedContentKind
    let body: Data
    let fileName: String?
    let mimeType: String?
    let caption: String?
    let duration: Int?

    init(
        kind: XauXatCodeLockedContentKind,
        body: Data,
        fileName: String? = nil,
        mimeType: String? = nil,
        caption: String? = nil,
        duration: Int? = nil
    ) {
        self.kind = kind
        self.body = body
        self.fileName = fileName
        self.mimeType = mimeType
        self.caption = caption
        self.duration = duration
    }

    init(text: String) {
        self.init(kind: .text, body: Data(text.utf8))
    }

    var text: String? {
        kind == .text ? String(data: body, encoding: .utf8) : nil
    }
}

enum XauXatCodeLockedContentError: Error, Equatable {
    case invalidCode
    case invalidAttemptLimit
    case invalidEnvelope
    case unsupportedVersion
    case keyDerivationFailed
    case authenticationFailed
}

struct XauXatCodeLockedEnvelope: Codable, Equatable {
    static let currentVersion = 1
    static let wireMarker = "xauxat-code-lock:v1:"
    static let fileWireMarker = "xauxat-code-lock-file:v1:"
    static let unsupportedClientMessage = "🔒 XauXat protected content. Update XauXat to unlock it."

    private static let kdfName = "pbkdf2-sha256"
    private static let iterations = 210_000
    private static let saltBytes = 16
    private static let keyBytes = 32
    static let allowedAttemptLimits = 1...20

    let version: Int
    let kind: XauXatCodeLockedContentKind
    let kdf: String
    let kdfIterations: Int
    let salt: Data
    let sealedPayload: Data
    let maxAttempts: Int?

    static func seal(
        _ payload: XauXatCodeLockedPayload,
        code: String,
        maxAttempts: Int? = nil
    ) throws -> Self {
        let normalizedCode = try normalized(code)
        if let maxAttempts, !allowedAttemptLimits.contains(maxAttempts) {
            throw XauXatCodeLockedContentError.invalidAttemptLimit
        }
        var salt = Data(count: saltBytes)
        let status = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, saltBytes, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw XauXatCodeLockedContentError.keyDerivationFailed }

        let key = try deriveKey(code: normalizedCode, salt: salt, iterations: iterations)
        let encodedPayload = try JSONEncoder.xauxatCanonical.encode(payload)
        let box = try ChaChaPoly.seal(
            encodedPayload,
            using: key,
            authenticating: authenticatedHeader(version: currentVersion, kind: payload.kind, maxAttempts: maxAttempts)
        )
        return Self(
            version: currentVersion,
            kind: payload.kind,
            kdf: kdfName,
            kdfIterations: iterations,
            salt: salt,
            sealedPayload: box.combined,
            maxAttempts: maxAttempts
        )
    }

    func open(code: String) throws -> XauXatCodeLockedPayload {
        guard version == Self.currentVersion else { throw XauXatCodeLockedContentError.unsupportedVersion }
        guard kdf == Self.kdfName,
              kdfIterations == Self.iterations,
              salt.count == Self.saltBytes,
              maxAttempts.map(Self.allowedAttemptLimits.contains) ?? true else {
            throw XauXatCodeLockedContentError.invalidEnvelope
        }
        let normalizedCode = try Self.normalized(code)
        let key = try Self.deriveKey(code: normalizedCode, salt: salt, iterations: kdfIterations)
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealedPayload)
            let cleartext = try ChaChaPoly.open(
                box,
                using: key,
                authenticating: Self.authenticatedHeader(version: version, kind: kind, maxAttempts: maxAttempts)
            )
            let payload = try JSONDecoder().decode(XauXatCodeLockedPayload.self, from: cleartext)
            guard payload.kind == kind else { throw XauXatCodeLockedContentError.invalidEnvelope }
            return payload
        } catch let error as XauXatCodeLockedContentError {
            throw error
        } catch {
            throw XauXatCodeLockedContentError.authenticationFailed
        }
    }

    func encoded() throws -> Data {
        try JSONEncoder.xauxatCanonical.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw XauXatCodeLockedContentError.invalidEnvelope
        }
    }

    func wireText() throws -> String {
        let encoded = try encoded().base64EncodedString()
        return "\(Self.unsupportedClientMessage)\n\(Self.wireMarker)\(encoded)"
    }

    static func fromWireText(_ text: String) throws -> Self {
        guard let markerRange = text.range(of: wireMarker),
              text[..<markerRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines) == unsupportedClientMessage,
              let data = Data(base64Encoded: String(text[markerRange.upperBound...]), options: [.ignoreUnknownCharacters]) else {
            throw XauXatCodeLockedContentError.invalidEnvelope
        }
        return try decode(data)
    }

    static func isWireText(_ text: String) -> Bool {
        (try? fromWireText(text)) != nil
    }

    static func fileWireText(kind: XauXatCodeLockedContentKind) -> String {
        "\(unsupportedClientMessage)\n\(fileWireMarker)\(kind.rawValue)"
    }

    static func fileKind(fromWireText text: String) -> XauXatCodeLockedContentKind? {
        guard isFileWireText(text), let markerRange = text.range(of: fileWireMarker) else { return nil }
        return XauXatCodeLockedContentKind(rawValue: String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isFileWireText(_ text: String) -> Bool {
        text.hasPrefix(unsupportedClientMessage) && text.contains(fileWireMarker)
    }

    private static func normalized(_ code: String) throws -> String {
        let normalized = code.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, normalized.utf8.count <= 128 else {
            throw XauXatCodeLockedContentError.invalidCode
        }
        return normalized
    }

    var attemptID: String {
        let envelopeData = (try? encoded()) ?? sealedPayload
        return SHA256.hash(data: envelopeData).map { String(format: "%02x", $0) }.joined()
    }

    private static func authenticatedHeader(
        version: Int,
        kind: XauXatCodeLockedContentKind,
        maxAttempts: Int?
    ) -> Data {
        let limit = maxAttempts.map { "|maxAttempts:\($0)" } ?? ""
        return Data("xauxat.code-lock|\(version)|\(kind.rawValue)|\(kdfName)|\(iterations)\(limit)".utf8)
    }

    private static func deriveKey(code: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(code.utf8)
        var key = [UInt8](repeating: 0, count: keyBytes)
        let result = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordBytes.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &key,
                    key.count
                )
            }
        }
        guard result == kCCSuccess else { throw XauXatCodeLockedContentError.keyDerivationFailed }
        return SymmetricKey(data: key)
    }
}

func xauXatIsCodeLockedText(_ text: String) -> Bool {
    text.hasPrefix(XauXatCodeLockedEnvelope.unsupportedClientMessage)
        && text.contains(XauXatCodeLockedEnvelope.wireMarker)
}

func xauXatIsCodeLockedFile(_ text: String, kind: XauXatCodeLockedContentKind? = nil) -> Bool {
    guard let fileKind = XauXatCodeLockedEnvelope.fileKind(fromWireText: text) else { return false }
    return kind == nil || fileKind == kind
}

func xauXatIsAnyCodeLockedContent(_ text: String) -> Bool {
    xauXatIsCodeLockedText(text) || XauXatCodeLockedEnvelope.isFileWireText(text)
}

func xauXatCodeLockedPreviewText(_ text: String) -> String {
    switch XauXatCodeLockedEnvelope.fileKind(fromWireText: text) {
    case .some(.image):
        return NSLocalizedString("Protected photo", comment: "code-locked photo placeholder")
    case .some(.audio):
        return NSLocalizedString("Protected audio", comment: "code-locked audio placeholder")
    case .some(.video):
        return NSLocalizedString("Protected video", comment: "code-locked video placeholder")
    case .some(.file):
        return NSLocalizedString("Protected file", comment: "code-locked file placeholder")
    default:
        break
    }
    if XauXatCodeLockedEnvelope.isFileWireText(text) {
        return NSLocalizedString("Protected content", comment: "code-locked content placeholder")
    }
    return xauXatIsCodeLockedText(text)
        ? NSLocalizedString("Protected message", comment: "code-locked message placeholder")
        : text
}

enum XauXatCodeLockedState: Equatable {
    case locked
    case unlocking
    case unlocked(XauXatCodeLockedPayload)
    case rejected(attempts: Int)
    case exhausted(attempts: Int)
}

@MainActor
final class XauXatCodeLockedSession: ObservableObject {
    @Published private(set) var state: XauXatCodeLockedState = .locked

    private let envelope: XauXatCodeLockedEnvelope
    private var attempts: Int
    private var operationID = UUID()

    init(envelope: XauXatCodeLockedEnvelope) {
        self.envelope = envelope
        attempts = xauXatCodeLockedAttemptCount(envelope.attemptID)
        if let maximum = envelope.maxAttempts, attempts >= maximum {
            state = .exhausted(attempts: attempts)
        }
    }

    var remainingAttempts: Int? {
        envelope.maxAttempts.map { max(0, $0 - attempts) }
    }

    var maximumAttempts: Int? { envelope.maxAttempts }

    func unlock(code: String) {
        if let maximum = envelope.maxAttempts, attempts >= maximum {
            state = .exhausted(attempts: attempts)
            return
        }
        operationID = UUID()
        let currentOperation = operationID
        state = .unlocking
        Task.detached(priority: .userInitiated) { [envelope] in
            let result = Result { try envelope.open(code: code) }
            await MainActor.run {
                guard currentOperation == self.operationID else { return }
                switch result {
                case let .success(payload):
                    self.attempts = 0
                    _ = xauXatSetCodeLockedAttemptCount(0, contentID: envelope.attemptID)
                    self.state = .unlocked(payload)
                case .failure:
                    self.attempts += 1
                    _ = xauXatSetCodeLockedAttemptCount(self.attempts, contentID: envelope.attemptID)
                    if let maximum = envelope.maxAttempts, self.attempts >= maximum {
                        self.state = .exhausted(attempts: self.attempts)
                    } else {
                        self.state = .rejected(attempts: self.attempts)
                    }
                }
            }
        }
    }

    func lock() {
        operationID = UUID()
        if let maximum = envelope.maxAttempts, attempts >= maximum {
            state = .exhausted(attempts: attempts)
        } else {
            state = .locked
        }
    }
}

private extension JSONEncoder {
    static var xauxatCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
