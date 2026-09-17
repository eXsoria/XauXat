#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <XauXat.app> [development|production]" >&2
  exit 64
fi

app_path=$1
expected_apns=${2:-}
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
main_plist="$app_path/Info.plist"
nse_path="$app_path/PlugIns/SimpleX NSE.appex"
share_path="$app_path/PlugIns/SimpleX SE.appex"

read_plist() {
  plutil -extract "$2" raw "$1"
}

assert_equal() {
  local actual=$1
  local expected=$2
  local label=$3
  if [[ "$actual" != "$expected" ]]; then
    echo "$label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

test -d "$app_path"
test -f "$main_plist"
test -d "$nse_path"
test -d "$share_path"

assert_equal "$(read_plist "$main_plist" CFBundleIdentifier)" "pt.exsoria.xauxat" "main bundle identifier"
assert_equal "$(read_plist "$nse_path/Info.plist" CFBundleIdentifier)" "pt.exsoria.xauxat.notification-service" "NSE bundle identifier"
assert_equal "$(read_plist "$share_path/Info.plist" CFBundleIdentifier)" "pt.exsoria.xauxat.share" "share bundle identifier"
assert_equal "$(read_plist "$main_plist" XauXatKeychainAccessGroup)" "$(read_plist "$nse_path/Info.plist" XauXatKeychainAccessGroup)" "main/NSE keychain group"
assert_equal "$(read_plist "$main_plist" XauXatKeychainAccessGroup)" "$(read_plist "$share_path/Info.plist" XauXatKeychainAccessGroup)" "main/share keychain group"

assert_equal "$(read_plist "$main_plist" BGTaskSchedulerPermittedIdentifiers.0)" "pt.exsoria.xauxat.receive" "background task identifier"

main_entitlements="$repo_root/apps/ios/SimpleX (iOS).entitlements"
if [[ "$expected_apns" == "production" ]]; then
  main_entitlements="$repo_root/apps/ios/XauXat Release.entitlements"
fi
nse_entitlements="$repo_root/apps/ios/SimpleX NSE/SimpleX NSE.entitlements"
share_entitlements="$repo_root/apps/ios/SimpleX SE/SimpleX SE.entitlements"

for entitlements in "$main_entitlements" "$nse_entitlements" "$share_entitlements"; do
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$entitlements")" "group.pt.exsoria.xauxat" "App Group in $entitlements"
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements")" '$(AppIdentifierPrefix)pt.exsoria.xauxat' "Keychain group in $entitlements"
done

if [[ -n "$expected_apns" ]]; then
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$main_entitlements")" "$expected_apns" "source APNs environment"
fi

if [[ -n "$expected_apns" ]]; then
  entitlements=$(mktemp)
  trap 'rm -f "$entitlements"' EXIT
  codesign -d --entitlements :- "$app_path" >"$entitlements" 2>/dev/null || true
  if [[ -s "$entitlements" ]] && plutil -extract aps-environment raw "$entitlements" >/dev/null 2>&1; then
    assert_equal "$(read_plist "$entitlements" aps-environment)" "$expected_apns" "APNs environment"
  fi
fi

echo "XauXat iOS identifiers verified."
