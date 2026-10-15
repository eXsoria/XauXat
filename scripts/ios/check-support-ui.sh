#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
cat > "$temp/SimpleXChat.swift" <<'SWIFT'
import Combine
public struct ReportReason { public var text: String { "Reason" } }
public final class ChatModel: ObservableObject {
    public static let shared = ChatModel()
    @Published public var chatRunning: Bool? = true
}
SWIFT
xcrun swiftc -emit-module -module-name SimpleXChat -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
  "$temp/SimpleXChat.swift" -emit-module-path "$temp/SimpleXChat.swiftmodule"
cat > "$temp/AppAdapters.swift" <<'SWIFT'
import SwiftUI
import SimpleXChat
final class AppTheme: ObservableObject {}
func planAndConnect(_ link: String, theme: AppTheme, dismiss: Bool) {}
SWIFT
# Compile the real report boundary; native group reports remain in the chat core.
python3 - "$root" "$temp" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
text = (root / 'apps/ios/Shared/Views/Helpers/ShareSheet.swift').read_text()
with (temp / 'AppAdapters.swift').open('a') as output:
    output.write(text[text.index('struct XauXatSafetyReport:'):text.index('func getTopViewController()')])
PY
files="$root/apps/ios/Shared/Views/UserSettings"
xcrun swiftc -swift-version 5 -typecheck -sdk "$sdk" -target arm64-apple-ios15.0-simulator -I "$temp" \
  "$temp/AppAdapters.swift" "$files/XauXatSupportModels.swift" \
  "$files/XauXatSupportClient.swift" "$files/XauXatSupportView.swift"
echo 'Native support UI type-checked for iOS 15 deployment.'
