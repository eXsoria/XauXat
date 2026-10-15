import Foundation
import Network
import SimpleXChat

private final class XauXatSupportNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
enum XauXatSupportClient {
    static var baseURL: URL? { xauXatSupportBaseURL(Bundle.main.object(forInfoDictionaryKey: "XauXatSupportURL") as? String) }

    static func policy() async throws -> XauXatSupportPolicy {
        try await request(path: "api/v1/policy")
    }

    static func send(_ submission: XauXatSupportRequest) async throws -> XauXatSupportTicket {
        try await request(path: "api/v1/tickets", body: submission.encoded())
    }

    static func ticket(_ receipt: XauXatSupportReceipt) async throws -> XauXatSupportTicket {
        try await request(path: "api/v1/tickets/" + receipt.id.uuidString.lowercased(), secret: receipt.secret)
    }

    static func followup(_ message: XauXatSupportFollowup, receipt: XauXatSupportReceipt) async throws -> XauXatSupportTicket {
        let body = try JSONEncoder().encode(message)
        guard body.count <= 24576 else { throw XauXatSupportError.tooLarge }
        return try await request(path: "api/v1/tickets/" + receipt.id.uuidString.lowercased() + "/messages", body: body, secret: receipt.secret)
    }

    private static func request<Result: Decodable>(path: String, body: Data? = nil, secret: String? = nil) async throws -> Result {
        guard let baseURL else { throw XauXatSupportError.unavailable }
        guard #available(iOS 17.0, *) else { throw XauXatSupportError.unsupported }
        guard case let .ready(port) = EmbeddedTorManager.shared.state,
              isXauXatManagedTorConfig(getNetCfg()),
              let proxyPort = NWEndpoint.Port(rawValue: port) else { throw XauXatSupportError.torNotReady }
        let configuration = URLSessionConfiguration.ephemeral
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: proxyPort))
        proxy.allowFailover = false
        // Separate stream credentials keep support requests isolated from chat streams.
        proxy.applyCredential(username: "xauxat-support-" + UUID().uuidString, password: UUID().uuidString)
        configuration.proxyConfigurations = [proxy]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: XauXatSupportNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let secret { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
        // System TLS verification is retained; redirects are never followed.
        let (data, response) = try await session.data(for: request)
        // A full conversation can include 30 messages, each up to 4,000 scalars.
        guard let http = response as? HTTPURLResponse, data.count <= 1048576 else { throw XauXatSupportError.response }
        guard (200...299).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServiceError.self, from: data), error.error.count <= 240 {
                throw XauXatSupportError.service(error.error)
            }
            throw XauXatSupportError.response
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    private struct ServiceError: Decodable { let error: String }
}
