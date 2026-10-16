#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

python3 - "$root" "$temp" <<'PY'
from pathlib import Path
import json
import sys

root, temp = map(Path, sys.argv[1:])
qr = (root / 'apps/ios/Shared/Views/NewChat/QRCode.swift').read_text(encoding='utf-8')
scanner = (root / 'apps/ios/Shared/Views/NewChat/NewChatView.swift').read_text(encoding='utf-8')
picker = (root / 'apps/ios/Shared/Views/Helpers/ImagePicker.swift').read_text(encoding='utf-8')
images = (root / 'apps/ios/SimpleXChat/ImageUtils.swift').read_text(encoding='utf-8')

def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

core = '\n'.join(declaration(qr, marker) for marker in [
    'enum XauXatQRCodeImageError:',
    'func xauXatReadQRCode(in ',
    'func xauXatQRCodeExportImage(',
])
fixtures = (root / 'scripts/ios/qr-image-tests/main.swift').read_text(encoding='utf-8')
delivery = declaration(scanner, 'private func deliverPhotoResult()')
(temp / 'main.swift').write_text('import Foundation\nimport CoreImage.CIFilterBuiltins\nimport ImageIO\n' + core + '\n' + fixtures + '\n', encoding='utf-8')
(temp / 'Delivery.swift').write_text('''
import Foundation
final class PhotoDelivery {
    var photoLibraryDismissed = false
    var readingPhoto = false
    var photoResult: Result<String, Error>?
    var values: [String] = []
    var failures = 0
    func processQRCode(_ result: Result<String, Error>) {
        switch result {
        case let .success(value): values.append(value)
        case .failure: failures += 1
        }
    }
''' + delivery + '''
    func deliver() { deliverPhotoResult() }
}
''', encoding='utf-8')

ui = 'import SwiftUI\nimport PhotosUI\nimport CoreImage.CIFilterBuiltins\nimport AVFoundation\nimport CodeScanner\n' + core
ui += '\n' + '\n'.join(declaration(qr, marker) for marker in [
    'func xauXatReadQRCodePhoto(',
    'private func xauXatQRCodeExifOrientation(',
    'struct QRCode: View',
    'private struct XauXatQRCodeLogo:',
    'private struct XauXatQRCodeMark:',
    'private func qrCodeImage(',
    'private func generateImage(',
])
ratio = next(line for line in qr.splitlines() if line.startswith('private let smallQRRatio'))
ui += '\n' + ratio
ui += '\nextension View {\n' + declaration(qr, 'func makeScreenshot(') + '\n}\n'
ui += '\nextension UIImage {\n' + declaration(images, 'public func replaceColor(') + '\n}\n'
ui += '\n' + declaration(picker, 'struct QRCodePhotoPicker:')
ui += '\n' + declaration(scanner, 'struct ScannerInView: View')
# Existing application services are not part of the image scanner. The real
# platform controls and pinned CodeScanner module are type-checked below.
ui += '''
func showShareSheet(items: [Any]) {}
let appSettingsURL = URL(string: UIApplication.openSettingsURLString)!
struct XauXatAppSwitcherProtection: ViewModifier {
    func body(content: Content) -> some View { content }
}
'''
(temp / 'QRViews.swift').write_text(ui, encoding='utf-8')
pins = json.loads((root / 'apps/ios/SimpleX.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text(encoding='utf-8'))['pins']
revision = next(pin['state']['revision'] for pin in pins if pin['identity'] == 'codescanner')
(temp / 'codescanner-revision').write_text(revision)
PY

swiftc "$temp/main.swift" "$temp/Delivery.swift" -o "$temp/qr-image-tests"
"$temp/qr-image-tests"

# Compile against the same dependency revision as the app, not a stand-in for
# its scan callback API. Only temporary checkouts are created.
git init -q "$temp/CodeScanner"
git -C "$temp/CodeScanner" fetch -q --depth=1 https://github.com/twostraws/CodeScanner.git "$(cat "$temp/codescanner-revision")"
git -C "$temp/CodeScanner" checkout -q --detach FETCH_HEAD
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
# SwiftPM normally generates this accessor for CodeScanner's image resources.
# Only the module interface is built here; no resource lookup is executed.
cat > "$temp/ResourceAccessor.swift" <<'SWIFT'
import Foundation
extension Bundle { static let module = Bundle.main }
SWIFT
xcrun swiftc -swift-version 5 -emit-module -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
  -module-name CodeScanner "$temp/CodeScanner/Sources/CodeScanner/"*.swift "$temp/ResourceAccessor.swift" \
  -emit-module-path "$temp/CodeScanner.swiftmodule"
xcrun swiftc -swift-version 5 -typecheck -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
  -I "$temp" "$temp/QRViews.swift"
echo 'Actual QR, photo picker and camera scanner views type-checked for iOS 15.'
