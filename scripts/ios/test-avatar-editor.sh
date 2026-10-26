#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
out=${AVATAR_TEST_OUTPUT:-"$temp/proof"}
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
python3 "$root/scripts/ios/avatar-editor-tests/make-project.py" "$root" "$temp/project"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 5 -typecheck -sdk "$sdk" -target arm64-apple-ios15.0-simulator "$temp/project/Camera.swift"
runtime=$(xcrun simctl list runtimes available --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS")]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
type=$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; print(next(d["identifier"] for d in json.load(sys.stdin)["devicetypes"] if d["name"]=="iPhone 14 Pro"))')
udid=$(xcrun simctl create XauXat-Avatar "$type" "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
set +e
xcodebuild -project "$temp/project/AvatarHarness.xcodeproj" -scheme AvatarHarness \
  -destination "platform=iOS Simulator,id=$udid" -parallel-testing-enabled NO \
  -derivedDataPath "$temp/build" -resultBundlePath "$out/AvatarEditor.xcresult" \
  test CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/tests.log"
result=${PIPESTATUS[0]}
set -e
if [[ -d "$out/AvatarEditor.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$out/AvatarEditor.xcresult" --output-path "$out/screenshots" || true
fi
exit "$result"
