import Foundation
import Security

enum XauXatSupportKind: String, Codable {
    case contactReport = "contact_report"
    case messageReport = "message_report"
    case support
}

enum XauXatSupportError: LocalizedError {
    case unavailable, torNotReady, unsupported, invalidReceipt, invalidRequest, tooLarge, response
    case service(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "The official support service is not configured in this build."
        case .torNotReady: "Wait for the private connection to be ready and try again. You can also deliberately open the official support website."
        case .unsupported: "Sending inside the app requires iOS 17 or later. You can use the official support website in your browser."
        case .invalidReceipt: "Paste the complete private receipt."
        case .invalidRequest: "Review the required fields and the optional content you chose to include."
        case .tooLarge: "The request is too large. Shorten the selected text or description."
        case .response: "Support could not confirm the request. Keep the private receipt and check it before retrying."
        case let .service(message): message
        }
    }
}

struct XauXatSupportReceipt: Equatable {
    let id: UUID
    let secret: String
    var value: String { id.uuidString.lowercased() + "." + secret }

    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw XauXatSupportError.invalidRequest
        }
        id = UUID()
        secret = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init(_ value: String) throws {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[0])),
              parts[1].count == 43,
              String(parts[1]).range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw XauXatSupportError.invalidReceipt
        }
        id = uuid
        secret = String(parts[1])
    }
}

struct XauXatSupportRequest: Encodable {
    let version = 1
    let id: String
    let secret: String
    let kind: XauXatSupportKind
    let reason: String
    let details: String
    let contactName: String?
    let selectedText: String?
    let messageType: String?
    let consent = true
    let consentVersion: String

    init(receipt: XauXatSupportReceipt, kind: XauXatSupportKind, reason: String, details: String, contactName: String? = nil, selectedText: String? = nil, messageType: String? = nil, consentVersion: String) throws {
        func valid(_ text: String, maximum: Int, required: Bool = false) -> Bool {
            text.unicodeScalars.count <= maximum && (!required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && !text.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" }
        }
        guard valid(reason, maximum: 120, required: true), valid(details, maximum: 4000, required: kind == .support),
              contactName.map({ valid($0, maximum: 128, required: true) }) ?? true,
              selectedText.map({ valid($0, maximum: 4000, required: true) }) ?? true,
              messageType.map({ valid($0, maximum: 64, required: true) }) ?? true,
              kind != .support || (contactName == nil && selectedText == nil && messageType == nil),
              kind == .messageReport || (selectedText == nil && messageType == nil),
              consentVersion == "2026-10-15" else { throw XauXatSupportError.invalidRequest }
        self.id = receipt.id.uuidString.lowercased()
        self.secret = receipt.secret
        self.kind = kind
        self.reason = reason
        self.details = details
        self.contactName = contactName
        self.selectedText = selectedText
        self.messageType = messageType
        self.consentVersion = consentVersion
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 24576 else { throw XauXatSupportError.tooLarge }
        return data
    }
}

struct XauXatSupportPolicy: Decodable {
    let consentVersion: String
    let contact: String
    let retentionDays: Int
}

struct XauXatSupportTicket: Decodable {
    struct Reply: Decodable, Identifiable {
        let id: String
        let text: String
        let createdAt: Int
        let sender: String
    }
    let id: String
    let reference: String
    let status: String
    let expiresAt: Int
    let replies: [Reply]
}

struct XauXatSupportFollowup: Encodable {
    let id = UUID().uuidString.lowercased()
    let text: String
    let consent = true
    let consentVersion = "2026-10-15"

    init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 4000,
              !value.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) else { throw XauXatSupportError.invalidRequest }
        self.text = value
    }
}

func xauXatSupportBaseURL(_ setting: String?) -> URL? {
    guard let setting, let url = URL(string: setting), url.scheme == "https",
          url.host?.isEmpty == false, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
    return url
}
