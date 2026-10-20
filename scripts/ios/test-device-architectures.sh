#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
printf 'int fixture(void) { return 0; }\n' > "$temp/fixture.c"
xcrun clang -target arm64-apple-ios15.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -c "$temp/fixture.c" -o "$temp/arm64.o"
xcrun clang -target x86_64-apple-macos14.0 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -c "$temp/fixture.c" -o "$temp/host.o"
python3 - "$temp" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys
root = Path(sys.argv[1])
app = root / 'Fixture.app'
for bundle in [app, app / 'PlugIns/Service.appex', app / 'Frameworks/Tor.framework']:
    bundle.mkdir(parents=True)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Fixture', 'CFBundleSupportedPlatforms': ['iPhoneOS']
    }))
    shutil.copyfile(root / 'arm64.o', bundle / 'Fixture')
PY
bash "$root/scripts/ios/verify-device-architectures.sh" "$temp/Fixture.app"
cp "$temp/host.o" "$temp/Fixture.app/Frameworks/Tor.framework/Fixture"
if bash "$root/scripts/ios/verify-device-architectures.sh" "$temp/Fixture.app" >/dev/null 2>&1; then
  echo 'Architecture guard accepted an Intel framework in an iPhone app' >&2
  exit 1
fi
cp "$temp/arm64.o" "$temp/Fixture.app/Frameworks/Tor.framework/Fixture"
/usr/libexec/PlistBuddy -c 'Set :CFBundleSupportedPlatforms:0 iPhoneSimulator' "$temp/Fixture.app/Info.plist"
if bash "$root/scripts/ios/verify-device-architectures.sh" "$temp/Fixture.app" >/dev/null 2>&1; then
  echo 'Architecture guard accepted a simulator app' >&2
  exit 1
fi
echo 'Device architecture positive and negative controls passed.'
