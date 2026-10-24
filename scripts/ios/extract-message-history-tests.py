"""Compile the production history loader with local store/lifecycle adapters."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
api = (root / "apps/ios/Shared/Model/SimpleXAPI.swift").read_text(encoding="utf-8")
start = api.index("@MainActor\nfunc waitForMessageHistoryAccess(")
end = api.index("\nfunc apiGetChatItemInfo(", start)
loader = (root / "apps/ios/Shared/Views/Chat/ChatItemsLoader.swift").read_text(encoding="utf-8")
loader = loader.replace("import SimpleXChat\n", "").replace("import SwiftUI\n", "")
loader = loader.split("private func indexToInsertAroundTest()", 1)[0]

def declaration(source, marker):
    start = source.index(marker)
    cursor = source.index("(", start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == "(") - (source[cursor] == ")")
        cursor += 1
    brace = source.index("{", cursor)
    cursor, depth = brace + 1, 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor].replace("private func ", "func ", 1)

model = (root / "apps/ios/Shared/Model/ChatModel.swift").read_text(encoding="utf-8")
navigation = "\nextension ItemsModel {\n" + "\n".join(
    declaration(model, marker) for marker in (
        "private func loadOpenChatAuthorized(",
        "private func loadOpenChatNoWaitAuthorized(",
    )
) + "\n}\n"
view = (root / "apps/ios/Shared/Views/Chat/ChatView.swift").read_text(encoding="utf-8")
assert view.count("retryMessageHistoryIfNeeded()") == 3, "Retry on appearance and foreground, including secondary histories"
assert "guard shouldRetryMessageHistory(chat: chat, im: im)" in view
chat_overload = "\n@MainActor\n" + declaration(api, "func loadChat(chat:") + "\n"
output.write_text("import Foundation\n" + api[start:end] + chat_overload + loader + navigation, encoding="utf-8")
