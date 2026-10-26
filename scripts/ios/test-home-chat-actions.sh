#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
out=${HOME_CHAT_TEST_OUTPUT:-"$temp/proof"}
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
python3 "$root/scripts/ios/home-chat-tests/make-project.py" "$root" "$temp/project"
xcodebuild -list -json -project "$temp/project/HomeChatHarness.xcodeproj" > "$out/project.json"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 5 -typecheck -parse-as-library -sdk "$sdk" \
  -target "$(uname -m)-apple-ios15.0-simulator" "$temp/project/Harness.swift" "$temp/project/Rows.swift"
runtime=$(xcrun simctl list runtimes available --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS")]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
type=$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; print(next(d["identifier"] for d in json.load(sys.stdin)["devicetypes"] if d["name"]=="iPhone 14 Pro"))')
udid=$(xcrun simctl create XauXat-Home-Chats "$type" "$runtime")
xcrun simctl boot "$udid"
python3 - "$udid" "$out/boot.log" <<'PY'
import subprocess
import sys
with open(sys.argv[2], "w") as log:
    try:
        subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b"],
                       stdout=log, stderr=subprocess.STDOUT, timeout=600, check=True)
    except subprocess.TimeoutExpired:
        raise SystemExit("Simulator boot did not finish within ten minutes; see boot.log")
PY
set +e
xcodebuild -project "$temp/project/HomeChatHarness.xcodeproj" -scheme HomeChatHarness \
  -destination "platform=iOS Simulator,id=$udid" -parallel-testing-enabled NO \
  -derivedDataPath "$temp/build" -resultBundlePath "$out/HomeChats.xcresult" \
  test CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/tests.log"
result=${PIPESTATUS[0]}
set -e
if [[ -d "$out/HomeChats.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$out/HomeChats.xcresult" --output-path "$out/screenshots" || true
fi
exit "$result"
