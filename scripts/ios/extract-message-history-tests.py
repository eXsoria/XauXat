"""Compile the production history loader with local store/lifecycle adapters."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
api = (root / "apps/ios/Shared/Model/SimpleXAPI.swift").read_text(encoding="utf-8")
start = api.index("@MainActor\nfunc loadChat(chatId:")
end = api.index("\nfunc apiGetChatItemInfo(", start)
loader = (root / "apps/ios/Shared/Views/Chat/ChatItemsLoader.swift").read_text(encoding="utf-8")
loader = loader.replace("import SimpleXChat\n", "").replace("import SwiftUI\n", "")
loader = loader.split("private func indexToInsertAroundTest()", 1)[0]
output.write_text("import Foundation\n" + api[start:end] + "\n" + loader, encoding="utf-8")
