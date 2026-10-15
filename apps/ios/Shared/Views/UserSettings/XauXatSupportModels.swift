import Foundation

// This is a public contact address, never an HTTP submission endpoint.
// Restrict configuration to native short contact links. The native core performs
// the actual link resolution, cryptographic validation and connection planning.
func xauXatSupportContactAddress(_ encoded: String?) -> String? {
    guard let encoded, encoded.count <= 1024,
          let data = Data(base64Encoded: encoded),
          let address = String(data: data, encoding: .utf8),
          let url = URLComponents(string: address),
          url.scheme == "https", url.user == nil, url.password == nil,
          url.port == nil, url.query == nil, url.path == "/a",
          let host = url.host, host.range(of: "^smp[0-9]+\\.simplex\\.im$", options: .regularExpression) != nil,
          let fragment = url.fragment,
          fragment.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { return nil }
    return address
}
