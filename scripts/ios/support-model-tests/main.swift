import Foundation

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else { fatalError(message) }
}
func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
let token = String(repeating: "a", count: 43)
let contact = "https://smp5.simplex.im/a#" + token
check(xauXatSupportContactAddress(b64(contact)) == contact, "Native short contact must round-trip")
check(xauXatSupportContactAddress(nil) == nil, "Missing configuration must not select an unrelated recipient")
check(xauXatSupportContactAddress("$(XAUXAT_SUPPORT_CONTACT_B64)") == nil, "Unresolved build setting must be unavailable")
check(xauXatSupportContactAddress("") == nil, "Empty configuration must be unavailable")
check(xauXatSupportContactAddress("not base64") == nil, "Malformed base64 must be unavailable")
for invalid in [
    "http://smp5.simplex.im/a#" + token,
    "https://smp5.simplex.im/api/v1/tickets#" + token,
    "https://smp5.simplex.im/a?body=private#" + token,
    "https://smp5.simplex.im/a#short",
    "https://smp5.simplex.im/a#" + token + ".",
    "https://smp5.simplex.im.evil.example/a#" + token,
    "https://user:password@smp5.simplex.im/a#" + token,
    "https://smp5.simplex.im:8443/a#" + token,
    "https://support.example.test/a#" + token,
    contact + "\nprivate message"
] {
    check(xauXatSupportContactAddress(b64(invalid)) == nil, "Configuration must reject non-contact or ambiguous destination: " + invalid)
}
print("Native support destination checks passed: \(checks)")
