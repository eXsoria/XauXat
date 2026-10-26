#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
out=${VOICE_TEST_OUTPUT:-"$temp/proof"}
mkdir -p "$out"
udid=""
cleanup() {
  if [[ -n "$udid" ]]; then
    xcrun simctl shutdown "$udid" || true
    xcrun simctl delete "$udid" || true
  fi
  rm -rf "$temp"
}
trap cleanup EXIT
swiftc "$root/apps/ios/Shared/Views/Chat/ComposeMessage/VoiceRecordingInteraction.swift" \
  "$root/scripts/ios/voice-recording-tests/InteractionTests.swift" -o "$temp/interaction-tests"
"$temp/interaction-tests" | tee "$out/interaction.log"
python3 "$root/scripts/ios/voice-recording-tests/make-project.py" "$root" "$temp/project"
xcodebuild -list -json -project "$temp/project/VoiceHarness.xcodeproj" > "$out/project.json"
# Compile before booting iOS: the Intel runner has limited memory, and a fresh
# simulator's migration should not compete with SwiftUI compilation.
xcodebuild -project "$temp/project/VoiceHarness.xcodeproj" -scheme VoiceHarness \
  -destination 'generic/platform=iOS Simulator' -parallel-testing-enabled NO \
  -derivedDataPath "$temp/build" build-for-testing CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/build.log"
runtime=$(xcrun simctl list runtimes available --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS")]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
type=$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; print(next(d["identifier"] for d in json.load(sys.stdin)["devicetypes"] if d["name"]=="iPhone 14 Pro"))')
udid=$(xcrun simctl create XauXat-Voice "$type" "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$temp/build/Build/Products/Debug-iphonesimulator/VoiceHarness.app"
xcrun simctl privacy "$udid" grant microphone pt.exsoria.voice-harness
set +e
xcodebuild -project "$temp/project/VoiceHarness.xcodeproj" -scheme VoiceHarness \
  -destination "platform=iOS Simulator,id=$udid" -parallel-testing-enabled NO \
  -derivedDataPath "$temp/build" -resultBundlePath "$out/VoiceRecording.xcresult" \
  test-without-building CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/tests.log"
result=${PIPESTATUS[0]}
set -e
if [[ -d "$out/VoiceRecording.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$out/VoiceRecording.xcresult" --output-path "$out/screenshots" || true
fi
exit "$result"
