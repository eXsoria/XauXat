#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
out=${STEALTH_TEST_OUTPUT:-"$temp/proof"}
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
runtime=$(xcrun simctl list runtimes available --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS")]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
udid=$(xcrun simctl create XauXat-Stealth com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro "$runtime")
for variant in Release Debug Missing; do
  configuration=$variant
  missing=0
  selection=(-skip-testing:VoiceHarnessUITests/StealthTests/testMissingModelPreservesOriginalRecording)
  if [[ "$variant" == Missing ]]; then
    configuration=Release
    missing=1
    selection=(-only-testing:VoiceHarnessUITests/StealthTests/testMissingModelPreservesOriginalRecording)
  fi
  STEALTH_TEST_MISSING_MODEL=$missing python3 "$root/scripts/ios/stealth-tests/make-project.py" "$root" "$temp/$variant/project"
  xcodebuild -project "$temp/$variant/project/VoiceHarness.xcodeproj" -scheme VoiceHarness \
    -configuration "$configuration" -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$temp/$variant/build" build-for-testing ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/$variant-build.log"
  app="$temp/$variant/build/Build/Products/$configuration-iphonesimulator/VoiceHarness.app"
  if [[ "$missing" == 0 ]]; then
    bash "$root/scripts/ios/verify-stealth-resources.sh" "$app"
  else
    test ! -d "$app/XauXatLLVC.mlmodelc"
  fi
  xcrun simctl boot "$udid" || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl uninstall "$udid" pt.exsoria.voice-harness || true
  xcrun simctl install "$udid" "$app"
  set +e
  xcodebuild -project "$temp/$variant/project/VoiceHarness.xcodeproj" -scheme VoiceHarness \
    -configuration "$configuration" -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO -derivedDataPath "$temp/$variant/build" \
    -resultBundlePath "$out/$variant.xcresult" test-without-building "${selection[@]}" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/$variant-tests.log"
  result=${PIPESTATUS[0]}
  set -e
  if [[ -d "$out/$variant.xcresult" ]]; then
    xcrun xcresulttool export attachments --path "$out/$variant.xcresult" --output-path "$out/$variant-screenshots" || true
  fi
  [[ "$result" == 0 ]] || exit "$result"
done
