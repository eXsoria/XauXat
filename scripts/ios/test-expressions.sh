#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
out=${EXPRESSION_TEST_OUTPUT:-"$temp/proof"}
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
python3 "$root/scripts/ios/expression-tests/make-project.py" "$root" "$temp/project"
xcodebuild -list -json -project "$temp/project/ExpressionsHarness.xcodeproj" > "$out/project.json"
# Compile before booting a cold simulator so compiler errors surface promptly.
xcodebuild -project "$temp/project/ExpressionsHarness.xcodeproj" -scheme ExpressionsHarness \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$temp/build" \
  build-for-testing CODE_SIGNING_ALLOWED=NO "ARCHS=$(uname -m)" ONLY_ACTIVE_ARCH=YES 2>&1 | tee "$out/build.log"
read -r runtime type < <(xcrun simctl list runtimes available --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS")]
for runtime in sorted(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True):
    for device in runtime.get("supportedDeviceTypes", []):
        if device["name"] == "iPhone 14 Pro":
            print(runtime["identifier"], device["identifier"])
            sys.exit()
sys.exit("No installed iOS runtime supports the iPhone 14 Pro test fixture")
')
udid=$(xcrun simctl create XauXat-Expressions "$type" "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
set +e
xcodebuild -project "$temp/project/ExpressionsHarness.xcodeproj" -scheme ExpressionsHarness \
  -destination "platform=iOS Simulator,id=$udid" -parallel-testing-enabled NO \
  -derivedDataPath "$temp/build" -resultBundlePath "$out/Expressions.xcresult" \
  test-without-building CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/tests.log"
result=${PIPESTATUS[0]}
set -e
if [[ -d "$out/Expressions.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$out/Expressions.xcresult" --output-path "$out/screenshots" || true
fi
exit "$result"
