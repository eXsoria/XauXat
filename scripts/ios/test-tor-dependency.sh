#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

python3 "$root/scripts/ios/verify-tor-dependency.py"
test "$(pod --version)" = '1.17.0'
pod install --project-directory="$root/apps/ios" --deployment
python3 "$root/scripts/ios/verify-tor-dependency.py" --installed

# A host-engine version check cannot catch CocoaPods selecting an iOS archive
# with a name that -ltor-nolzma cannot resolve. Link the actual generated wrapper
# for both ARM64 iOS platforms before running the host sanitizers.
for sdk in iphoneos iphonesimulator; do
  xcodebuild -project "$root/apps/ios/Pods/Pods.xcodeproj" -target Tor \
    -configuration Release -sdk "$sdk" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    BUILD_DIR="$temp/build-$sdk" OBJROOT="$temp/objects-$sdk" \
    CONFIGURATION_BUILD_DIR="$temp/products-$sdk" CODE_SIGNING_ALLOWED=NO build
  binary="$temp/products-$sdk/Tor.framework/Tor"
  test -f "$binary"
  file "$binary" | grep -q arm64
  xcrun vtool -show-build "$binary" | grep -q 'platform IOS'
done

tor="$root/apps/ios/Pods/Tor"
engine=$(python3 - "$tor/tor-nolzma.xcframework" "$temp" "$root" <<'PY'
import json
from pathlib import Path
import platform
import plistlib
import sys
import urllib.request

framework, temp, root = map(Path, sys.argv[1:])
arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
with (framework / 'Info.plist').open('rb') as stream:
    libraries = plistlib.load(stream)['AvailableLibraries']
lib = next(lib for lib in libraries if lib['SupportedPlatform'] == 'macos'
           and arch in lib['SupportedArchitectures'])
print(framework / lib['LibraryIdentifier'] / lib['LibraryPath'])
print(framework / lib['LibraryIdentifier'] / lib['HeadersPath'])
# Derive the wrapper pin from the same spec that installed the engine.
spec = json.loads((root / 'apps/ios/podspecs/Tor.podspec.json').read_text())
url = 'https://raw.githubusercontent.com/iCepa/Tor.framework/' + spec['source']['commit'] + '/Sources/CTor/TORThread.m'
(temp / 'TORThread.m').write_bytes(urllib.request.urlopen(url, timeout=30).read())
PY
)
library=$(printf '%s\n' "$engine" | head -1)
headers=$(printf '%s\n' "$engine" | tail -1)
sources="$tor/Sources"
flags=(-fobjc-arc -fsanitize=address -framework Foundation -framework CFNetwork
       -I "$sources/TorCore/include" -I "$sources/CTor/include" -I "$headers"
       "$library" -lz)
harness="$root/scripts/ios/tor-recovery-tests/EngineVersion.m"

clang "${flags[@]}" "$temp/TORThread.m" "$harness" -o "$temp/upstream"
if ASAN_OPTIONS=detect_leaks=0 "$temp/upstream" > "$temp/upstream.log" 2>&1; then
  echo 'Expected the pristine wrapper argv overflow to fail under AddressSanitizer.' >&2
  exit 1
fi
grep -Eq 'AddressSanitizer: (dynamic-)?stack-buffer-overflow' "$temp/upstream.log"
echo 'Reproduced the pristine wrapper argv overflow in the latest wrapper/engine.'

python3 "$root/scripts/ios/patch-tor-thread.py" "$temp/TORThread.m"
python3 "$root/scripts/ios/patch-tor-thread.py" "$temp/TORThread.m"
cmp "$temp/TORThread.m" "$sources/CTor/TORThread.m"
clang "${flags[@]}" "$sources/CTor/TORThread.m" "$harness" -o "$temp/patched"
ASAN_OPTIONS=detect_leaks=0 "$temp/patched" > "$temp/patched.log" 2>&1
cat "$temp/patched.log"
grep -Fq 'Tor version 0.4.9.17' "$temp/patched.log"
echo 'Patched production wrapper executed Tor 0.4.9.17 without an argv overflow.'
