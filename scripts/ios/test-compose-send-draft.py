#!/usr/bin/env python3
"""Run the composer's send completion and chat draft restoration with synthetic state."""
from pathlib import Path
import subprocess
import tempfile

ios = Path(__file__).resolve().parents[2] / "apps/ios/Shared"
composer = (ios / "Views/Chat/ComposeMessage/ComposeView.swift").read_text()
chat = (ios / "Views/Chat/ChatView.swift").read_text()
model = (ios / "Model/ChatModel.swift").read_text()


def section(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


finish = section(composer, "        await MainActor.run {\n            if let submittedDraftRevision",
                 "        return sent").split("await MainActor.run {", 1)[1].rsplit("}", 1)[0]
sections = {
    "// draft kind": section(composer, "    var retryableMessageDraft:", "    var manyMediaPreviews:"),
    "// capture": section(composer, "        let submittedDraftRevision =", "        let attachmentPreparationStarted"),
    "// revision": section(model, "    private(set) var draftRevision:", "    // chat id with chat scope").replace("@Published ", ""),
    "// cleanup": section(composer, "    private func clearCurrentDraft(", "    // Spec:"),
    "// restore": section(chat, "        if chatModel.draftChatId == draftChatId(cInfo.id,", "        if chat.chatStats.unreadChat"),
    "// complete": finish,
}
fixture = """
import Foundation

enum Preview { case noPreview, linkPreview, chatLinkPreview, voicePreview, mediaPreviews, filePreview }
struct ComposeState {
    var message = ""
    var preview = Preview.noPreview
    var liveMessage: Int?
    var editing = false, forwarding = false, reporting = false, inProgress = false
    // draft kind
}
struct Info {
    var id = "test-chat"
    func groupChatScope() -> Int { 0 }
}
struct Chat {
    var chatInfo = Info()
    var id: String { chatInfo.id }
}
final class Model {
    // revision
    var draftChatId: String?
}
func draftChatId(_ id: String, _ scope: Int) -> String { id }

final class Composer {
    var chat = Chat()
    let chatModel = Model()
    var composeState = ComposeState(message: "draft")
    init() {
        chatModel.draft = composeState
        chatModel.draftChatId = chat.id
    }
    func clearState(live: Bool) {
        if !live { composeState = ComposeState() }
    }
    // cleanup
    func restore() {
        let cInfo = chat.chatInfo
        // restore
    }
    func send(result sent: Int?, live: Bool = false, whilePending: () -> Void = {}) {
        // capture
        composeState.inProgress = true
        whilePending()
        // complete
    }
}

var failures = 0
func check(_ result: Bool, _ name: String) {
    print((result ? "PASS " : "FAIL ") + name)
    if !result { failures += 1 }
}
for (preview, name) in [(Preview.noPreview, "text"), (.linkPreview, "link"),
                        (.voicePreview, "voice")] {
    let rejected = Composer()
    rejected.composeState.preview = preview
    rejected.send(result: nil)
    check(rejected.composeState.message == "draft" && !rejected.composeState.inProgress,
          "rejected " + name + " remains editable")
    let accepted = Composer()
    accepted.composeState.preview = preview
    accepted.send(result: 1)
    accepted.restore()
    check(accepted.composeState.message.isEmpty, "accepted " + name + " stays cleared after reopening")
}
let other = Composer()
other.chatModel.draftChatId = "other-chat"
other.send(result: 1)
check(other.chatModel.draft != nil, "another chat keeps its draft")

let newer = Composer()
newer.send(result: 1) {
    newer.chatModel.draft = ComposeState(message: "replacement")
}
check(newer.chatModel.draft?.message == "replacement", "replacement draft survives late completion")

let forward = Composer()
forward.composeState.forwarding = true
forward.send(result: 1)
check(forward.composeState.message == "draft", "forward restores existing draft")
exit(failures == 0 ? 0 : 1)
"""
for label, production in sections.items():
    assert fixture.count(label) == 1
    fixture = fixture.replace(label, production)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    test = root / "ComposeDraft.swift"
    test.write_text(fixture)
    subprocess.run(["xcrun", "swift", "-module-cache-path", str(root / "modules"), str(test)], check=True)
