#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
out=${CALL_GRAPH_OUTPUT:-"$temp/proof"}
mkdir -p "$out" "$temp/CallGraphProbe.app"
udid=""
cleanup() {
  if [[ -n "$udid" ]]; then xcrun simctl shutdown "$udid" || true; xcrun simctl delete "$udid" || true; fi
  rm -rf "$temp"
}
trap cleanup EXIT
app="$temp/CallGraphProbe.app"
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib,sys
Path(sys.argv[1], 'Info.plist').write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'pt.exsoria.call-graph-probe','CFBundleExecutable':'Probe',
 'CFBundleName':'CallGraphProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1',
 'CFBundleShortVersionString':'1.0','MinimumOSVersion':'15.0',
 'NSMicrophoneUsageDescription':'Exercise synthetic call audio graphs',
 'UILaunchScreen':{},'UIDeviceFamily':[1]
}))
PY
xcrun --sdk iphonesimulator clang -fobjc-arc -fblocks -target "$(uname -m)-apple-ios15.0-simulator" \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -framework UIKit -framework Foundation -framework AVFoundation \
  "$root/scripts/ios/call-audio-tests/GraphProbe.m" -o "$app/Probe"
codesign --force --sign - "$app"
runtime=$(xcrun simctl list runtimes available --json | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS")]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')
udid=$(xcrun simctl create XauXat-CallGraph com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant microphone pt.exsoria.call-graph-probe
data=$(xcrun simctl get_app_container "$udid" pt.exsoria.call-graph-probe data)
for variant in direct-default direct-voice sink-pitch-default sink-pitch-voice; do
  xcrun simctl launch "$udid" pt.exsoria.call-graph-probe "$variant"
  for attempt in {1..30}; do
    [[ -f "$data/Documents/$variant.json" ]] && break
    sleep 1
  done
  cp "$data/Documents/$variant.json" "$out/$variant.json"
  cat "$out/$variant.json"
  xcrun simctl terminate "$udid" pt.exsoria.call-graph-probe || true
  python3 - "$out/$variant.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if r['case'].startswith('direct'):
    assert r['stage']=='passed',r
else:
    # Negative control: the old graph must reproduce the specific converter
    # assertion, rather than passing because of a session/fixture failure.
    assert r['stage']=='prepare' and r.get('exception')=='com.apple.coreaudio.avfaudio' and 'isInputConnToConverter' in r.get('reason',''),r
PY
done
