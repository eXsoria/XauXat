import SwiftUI

struct XauXatSupportHomeView: View {
    var body: some View {
        List {
            Section {
                NavigationLink("Contact XauXat") { XauXatSupportComposeView() }
                NavigationLink("Follow a request") { XauXatSupportTrackView() }
            } footer: {
                Text("Requests are private to XauXat support. You review the data before sending and receive a private receipt for replies.")
            }
            XauXatSupportWebsiteSection()
        }
        .navigationTitle("Support & safety")
    }
}

struct XauXatSupportWebsiteSection: View {
    var body: some View {
        if let url = XauXatSupportClient.baseURL {
            Section {
                ExternalLink("Official support website", destination: url)
                ExternalLink("Support privacy policy", destination: url.appendingPathComponent("privacy"))
                ExternalLink("Community rules", destination: url.appendingPathComponent("rules"))
            } footer: {
                Text("Opening a link uses your external browser and its network settings. No report content is passed to it automatically.")
            }
        }
    }
}

struct XauXatSupportComposeView: View {
    @Environment(\.dismiss) private var dismiss
    var report: XauXatSafetyReport? = nil
    @State private var reason = "Technical problem"
    @State private var details = ""
    @State private var includeName = false
    @State private var includeText = false
    @State private var consent = false
    @State private var policy: XauXatSupportPolicy?
    @State private var receipt: XauXatSupportReceipt?
    @State private var prepared: XauXatSupportRequest?
    @State private var ticket: XauXatSupportTicket?
    @State private var attempted = false
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Form {
            if ticket == nil {
                Section {
                    if let report { Text(report.reason) }
                    else {
                        Picker("Reason", selection: $reason) {
                            Text("Technical problem").tag("Technical problem")
                            Text("Privacy or safety question").tag("Privacy or safety question")
                            Text("Other").tag("Other")
                        }
                    }
                    Text("Describe only what support needs to know.").font(.footnote)
                    TextEditor(text: $details).frame(minHeight: 100)
                    if let report, !report.contactName.isEmpty {
                        Toggle("Include the displayed contact name", isOn: $includeName)
                    }
                    if report?.selectedText?.isEmpty == false {
                        Toggle("Include text from this selected message", isOn: $includeText)
                    }
                } footer: {
                    Text("Chat history, media, files, your profile identity, keys and device tokens are not collected automatically. Blocking remains a separate immediate action.")
                }
                .disabled(prepared != nil || busy)

                if let prepared {
                    Section(header: Text("Exactly what will be sent")) {
                        Text(prepared.kind == .support ? "Support request" : "Safety report")
                        Text("Reason: \(prepared.reason)")
                        if !prepared.details.isEmpty { Text(prepared.details) }
                        if let type = prepared.messageType { Text("Selected type: \(type)") }
                        if let name = prepared.contactName { Text("Contact name: \(name)") }
                        if let text = prepared.selectedText { Text(text) }
                        if let policy {
                            Text("Recipient: XauXat support · \(policy.contact)")
                            Text("Support can read this submission. It expires \(policy.retentionDays) days after its latest activity.")
                        }
                        Toggle("I reviewed these data and agree to send them under the support privacy policy", isOn: $consent)
                            .disabled(attempted)
                        if !attempted {
                            Button("Edit") { self.prepared = nil; receipt = nil; consent = false }
                        }
                        Button(attempted ? "Retry this same request" : "Send to XauXat") { Task { await send() } }
                            .disabled(!consent || busy)
                    }
                } else {
                    Section {
                        Button("Review before sending") { prepare() }.disabled(policy == nil || busy)
                        if policy == nil { Button("Load support policy") { Task { await loadPolicy() } }.disabled(busy) }
                    }
                }
            }

            if let receipt, attempted {
                Section(header: Text(ticket == nil ? "Keep this receipt" : "Request received")) {
                    if let ticket { Text(ticket.reference).font(.footnote.monospaced()) }
                    Text("Save the private receipt to read replies. Anyone with it can read them; there is no account-based recovery.")
                    Button(copied ? "Copied for 5 minutes" : "Copy private receipt") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": receipt.value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                        copied = true
                    }
                    NavigationLink("Check request and replies") { XauXatSupportTrackView(initialReceipt: receipt.value) }
                    Text("Closing this screen clears its copy of the private receipt. Save it first.").font(.footnote)
                }
            }
            if busy { ProgressView() }
            if let error { Section { Text(error).foregroundColor(.red) } }
            XauXatSupportWebsiteSection()
        }
        .navigationTitle(report?.title ?? "Contact XauXat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
        .task { await loadPolicy() }
    }

    @MainActor private func loadPolicy() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await XauXatSupportClient.policy()
            guard value.consentVersion == "2026-10-15", (7...365).contains(value.retentionDays) else { throw XauXatSupportError.invalidRequest }
            policy = value
        } catch { self.error = error.localizedDescription }
    }

    private func prepare() {
        error = nil
        do {
            guard let policy else { throw XauXatSupportError.unavailable }
            let receipt = try XauXatSupportReceipt()
            let value = try XauXatSupportRequest(receipt: receipt, kind: report?.kind ?? .support,
                reason: report?.reason ?? reason, details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                contactName: includeName ? report?.contactName : nil,
                selectedText: includeText ? report?.selectedText : nil,
                messageType: report?.messageType, consentVersion: policy.consentVersion)
            _ = try value.encoded()
            self.receipt = receipt; prepared = value; consent = false
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func send() async {
        guard let prepared, consent else { return }
        busy = true; attempted = true; error = nil
        defer { busy = false }
        do { ticket = try await XauXatSupportClient.send(prepared) }
        catch { self.error = error.localizedDescription }
    }
}

struct XauXatSupportTrackView: View {
    @State private var receiptText: String
    @State private var ticket: XauXatSupportTicket?
    @State private var busy = false
    @State private var error: String?
    @State private var additionalText = ""
    @State private var reviewed = false
    @State private var pendingFollowup: XauXatSupportFollowup?

    init(initialReceipt: String = "") { _receiptText = State(initialValue: initialReceipt) }

    var body: some View {
        Form {
            Section {
                SecureField("Paste private receipt", text: $receiptText)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .disabled(pendingFollowup != nil || busy)
                Button("Check for a reply") { Task { await check() } }.disabled(busy || pendingFollowup != nil)
            } footer: { Text("Only the private receipt grants access. It is not stored by this screen after you leave.") }
            if busy { ProgressView() }
            if let ticket {
                Section {
                    Text(ticket.reference).font(.footnote.monospaced())
                    Text("Status: \(ticket.status)")
                    Text("Expires: \(Date(timeIntervalSince1970: TimeInterval(ticket.expiresAt)).formatted(date: .abbreviated, time: .omitted))")
                }
                Section(header: Text("Request conversation")) {
                    if ticket.replies.isEmpty { Text("No reply yet. Check again later.") }
                    ForEach(ticket.replies) { reply in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(reply.sender == "support" ? "XauXat support" : "You").font(.caption).bold()
                            Text(reply.text)
                            Text(Date(timeIntervalSince1970: TimeInterval(reply.createdAt)).formatted()).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Section(header: Text("Add information")) {
                    TextEditor(text: $additionalText).frame(minHeight: 90).disabled(pendingFollowup != nil || busy)
                    Text("Only this text will be sent to XauXat support. Do not paste keys or full chat histories.").font(.footnote)
                    Toggle("I reviewed this text and agree to send it under the support privacy policy", isOn: $reviewed).disabled(pendingFollowup != nil)
                    Button(pendingFollowup == nil ? "Send additional information" : "Retry this same message") { Task { await followup() } }
                        .disabled(!reviewed || busy)
                }
            }
            if let error { Section { Text(error).foregroundColor(.red) } }
            XauXatSupportWebsiteSection()
        }
        .navigationTitle("Follow a request")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor private func check() async {
        busy = true; error = nil; ticket = nil
        defer { busy = false }
        do { ticket = try await XauXatSupportClient.ticket(XauXatSupportReceipt(receiptText)) }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func followup() async {
        guard reviewed else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let receipt = try XauXatSupportReceipt(receiptText)
            if pendingFollowup == nil { pendingFollowup = try XauXatSupportFollowup(additionalText) }
            guard let pendingFollowup else { return }
            ticket = try await XauXatSupportClient.followup(pendingFollowup, receipt: receipt)
            self.pendingFollowup = nil; additionalText = ""; reviewed = false
        } catch { self.error = error.localizedDescription }
    }
}
