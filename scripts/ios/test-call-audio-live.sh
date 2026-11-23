#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
out=${CALL_LIVE_OUTPUT:-"$temp/proof"}
mkdir -p "$out" "$temp/CallAudioLive.app"
touch "$temp/started"
udid=""
cleanup() {
  if [[ -n "$udid" ]]; then xcrun simctl shutdown "$udid" || true; xcrun simctl delete "$udid" || true; fi
  rm -rf "$temp"
}
trap cleanup EXIT
python3 "$root/scripts/ios/call-audio-tests/make-live-harness.py" "$root" "$temp/source"
curl --fail --location --retry 2 --silent --show-error \
  https://github.com/simplex-chat/WebRTC/releases/download/110.0.0/WebRTC-M110.0.0.xcframework.zip -o "$temp/WebRTC.zip"
echo '2598307f788ab668e0f42b2a1daef4306adbb9ec9c3959441064e8e84f7310ee  '"$temp/WebRTC.zip" | shasum -a 256 -c -
unzip -q "$temp/WebRTC.zip" -d "$temp/sdk"
framework=$(python3 - "$temp/sdk" <<'PY'
import plistlib,sys
from pathlib import Path
sdk=next(Path(sys.argv[1]).rglob('WebRTC.xcframework'))
info=plistlib.loads((sdk/'Info.plist').read_bytes())
item=next(i for i in info['AvailableLibraries'] if i['SupportedPlatform']=='ios' and i.get('SupportedPlatformVariant')=='simulator')
print(sdk/item['LibraryIdentifier'])
PY
)
app="$temp/CallAudioLive.app"
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib,sys
Path(sys.argv[1], 'Info.plist').write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'pt.exsoria.call-audio-live','CFBundleExecutable':'Live',
 'CFBundleName':'CallAudioLive','CFBundlePackageType':'APPL','CFBundleVersion':'1',
 'CFBundleShortVersionString':'1.0','MinimumOSVersion':'15.0',
 'NSMicrophoneUsageDescription':'Exercise synthetic call audio',
 'UIBackgroundModes':['audio'],'UILaunchScreen':{},'UIDeviceFamily':[1]
}))
PY
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
target="$(uname -m)-apple-ios15.0-simulator"
xcrun --sdk iphonesimulator clang -fobjc-arc -fblocks -target "$target" -isysroot "$sdk" \
  -c "$temp/source/objc.m" -o "$temp/objc.o"
xcrun --sdk iphonesimulator swiftc -O -swift-version 5 -target "$target" -sdk "$sdk" \
  -F "$framework" -framework WebRTC -import-objc-header "$temp/source/objc.h" \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  "$temp/source/Device.swift" "$temp/source/LLVC.swift" "$temp/source/Presets.swift" \
  "$temp/source/main.swift" "$temp/objc.o" -o "$app/Live" 2>&1 | tee "$out/build.log"
mkdir -p "$app/Frameworks"
cp -R "$framework/WebRTC.framework" "$app/Frameworks/"
xcrun coremlcompiler compile "$root/apps/ios/Shared/Views/Call/XauXatLLVC.mlpackage" "$app" --deployment-target 15.0 --platform iphonesimulator
xcrun actool "$temp/source/Ambience.xcassets" --compile "$app" --platform iphonesimulator \
  --minimum-deployment-target 15.0 --target-device iphone --output-partial-info-plist "$temp/assets.plist"
codesign --force --deep --sign - "$app"
runtime=$(xcrun simctl list runtimes available --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS")]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
udid=$(xcrun simctl create XauXat-CallAudioLive com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant microphone pt.exsoria.call-audio-live
data=$(xcrun simctl get_app_container "$udid" pt.exsoria.call-audio-live data)
for variant in ${CALL_LIVE_CASES:-record-default play-default record-voice play-voice}; do
  launch=$(xcrun simctl launch --stdout="$out/$variant.stdout.log" --stderr="$out/$variant.stderr.log" "$udid" pt.exsoria.call-audio-live "$variant")
  echo "$launch"
  for attempt in {1..75}; do
    [[ -f "$data/Documents/$variant.json" ]] && break
    sleep 1
  done
  if [[ -f "$data/Documents/$variant.progress.json" ]]; then cp "$data/Documents/$variant.progress.json" "$out/"; fi
  if [[ ! -f "$data/Documents/$variant.json" ]]; then
    pid=${launch##*: }
    sample "$pid" 3 -file "$out/$variant.sample.txt" || true
    xcrun simctl spawn "$udid" log show --last 3m --style compact --predicate 'process == "Live" OR eventMessage CONTAINS "call-audio-live"' > "$out/$variant.system.log" || true
    mkdir -p "$out/crashes"
    find "$HOME/Library/Logs/DiagnosticReports" -type f -name 'Live*' -newer "$temp/started" -exec cp {} "$out/crashes/" \; || true
    echo "Missing result for $variant; saved progress, process sample and crash diagnostics" >&2
    exit 1
  fi
  cp "$data/Documents/$variant.json" "$out/$variant.json"
  cat "$out/$variant.json"
  xcrun simctl terminate "$udid" pt.exsoria.call-audio-live || true
  python3 - "$out/$variant.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r['stage']=='passed',r
PY
done
