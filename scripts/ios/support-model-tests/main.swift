import Foundation

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else { fatalError(message) }
}
func rejects(_ message: String, _ operation: () throws -> Void) {
    checks += 1
    do { try operation(); fatalError(message) } catch { }
}

let receipt = try XauXatSupportReceipt()
check(receipt.secret.count == 43, "Private receipt must contain a 256-bit token")
check(try XauXatSupportReceipt(receipt.value) == receipt, "Receipt must round-trip without changing secret case")
let uppercaseID = receipt.id.uuidString.uppercased() + "." + receipt.secret
check(try XauXatSupportReceipt(uppercaseID) == receipt, "UUID casing must not change the secret")
rejects("Missing secret must be rejected") { _ = try XauXatSupportReceipt(receipt.id.uuidString) }
rejects("Query-shaped receipt must be rejected") { _ = try XauXatSupportReceipt(receipt.value + "?extra") }
let minimal = try XauXatSupportRequest(receipt: receipt, kind: .contactReport, reason: "Spam", details: "", consentVersion: "2026-10-15")
let payload = try JSONSerialization.jsonObject(with: minimal.encoded()) as! [String: Any]
check(payload["contactName"] == nil && payload["selectedText"] == nil && payload["messageType"] == nil, "Chat identity and content must be opt-in")
check(Set(payload.keys) == Set(["version", "id", "secret", "kind", "reason", "details", "consent", "consentVersion"]), "No profile, device or chat metadata may be automatically added")
check(payload["consent"] as? Bool == true, "Explicit send must record consent")
let selected = try XauXatSupportRequest(receipt: receipt, kind: .messageReport, reason: "Spam", details: "", contactName: "Chosen name", selectedText: "Selected message only", messageType: "Text", consentVersion: "2026-10-15")
let selectedJSON = try JSONSerialization.jsonObject(with: selected.encoded()) as! [String: Any]
check(selectedJSON["selectedText"] as? String == "Selected message only", "Only chosen text may be included")
rejects("Support must reject attaching chat data") { _ = try XauXatSupportRequest(receipt: receipt, kind: .support, reason: "Help", details: "Problem", contactName: "Forbidden", consentVersion: "2026-10-15") }
rejects("Blank support requests must be rejected") { _ = try XauXatSupportRequest(receipt: receipt, kind: .support, reason: "Help", details: " ", consentVersion: "2026-10-15") }
rejects("Old consent version must be rejected") { _ = try XauXatSupportRequest(receipt: receipt, kind: .support, reason: "Help", details: "Problem", consentVersion: "old") }
rejects("Control characters must be rejected") { _ = try XauXatSupportFollowup("Unsafe\u{1b}[31m") }
let followup = try XauXatSupportFollowup("  Additional information  ")
check(followup.text == "Additional information", "Follow-up must trim surrounding whitespace")
let first = try JSONSerialization.jsonObject(with: JSONEncoder().encode(followup)) as! NSDictionary
let retry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(followup)) as! NSDictionary
check(first == retry, "Retrying a frozen follow-up must preserve its identifier and data")
let emoji = String(repeating: "😀", count: 4000)
let oversized = try XauXatSupportRequest(receipt: receipt, kind: .messageReport, reason: "Spam", details: emoji, selectedText: emoji, consentVersion: "2026-10-15")
rejects("UTF-8 body limit must be enforced") { _ = try oversized.encoded() }
check(xauXatSupportBaseURL("https://support.example.test") != nil, "Configured HTTPS origin must be accepted")
for url in ["http://support.example.test", "https://user:password@support.example.test", "https://support.example.test/path", "https://support.example.test?secret=x", "https://support.example.test#receipt"] {
    check(xauXatSupportBaseURL(url) == nil, "Unsafe or ambiguous support origin must be rejected")
}
print("Support model invariants passed: \(checks)")
