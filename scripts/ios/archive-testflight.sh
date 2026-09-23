#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
workspace="$repo_root/apps/ios/SimpleX.xcworkspace"
scheme="SimpleX (iOS)"
export_options_source="$repo_root/apps/ios/XauXat App Store ExportOptions.plist"
output_dir="$repo_root/.xauxat-release"
native_core_archive_dir=""
team_id=${XAUXAT_DEVELOPMENT_TEAM:-}
upload=false

usage() {
  cat <<'EOF'
usage: archive-testflight.sh --team-id TEAM_ID [options]

Options:
  --native-core-archive-dir DIR  Prepare the fork-built iOS core from DIR.
                                 DIR must contain pkg-ios-aarch64-swift-json.zip.
  --output-dir DIR               Store the archive and export in DIR.
  --upload                       Upload to App Store Connect after archiving.
                                 Without this flag, export an IPA locally.
  --team-id TEAM_ID              Apple Developer team ID. Alternatively set
                                 XAUXAT_DEVELOPMENT_TEAM.
  -h, --help                     Show this help.

The script never stores Apple credentials or the team ID in the repository.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --native-core-archive-dir)
      native_core_archive_dir=${2:-}
      shift 2
      ;;
    --output-dir)
      output_dir=${2:-}
      shift 2
      ;;
    --team-id)
      team_id=${2:-}
      shift 2
      ;;
    --upload)
      upload=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "A 10-character Apple team ID is required via --team-id or XAUXAT_DEVELOPMENT_TEAM." >&2
  exit 64
fi

if [[ -n "$native_core_archive_dir" ]]; then
  test -f "$native_core_archive_dir/pkg-ios-aarch64-swift-json.zip"
  "$repo_root/scripts/xauxat/prepare-ios-libs.sh" \
    --archive-dir "$native_core_archive_dir" \
    --device-only \
    --local-build
fi

library_count=$(find "$repo_root/apps/ios/Libraries/ios" -maxdepth 1 -type f -name '*.a' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$library_count" != "5" ]]; then
  echo "Expected five fork-built iOS static libraries; found $library_count." >&2
  echo "Pass --native-core-archive-dir with the native-core artifact from the current XauXat CI revision." >&2
  exit 1
fi

test -f "$workspace/contents.xcworkspacedata"
test -f "$export_options_source"
test "$(pod --version)" = "1.17.0"

"$repo_root/scripts/ios/verify-nse-tor-policy.sh"
"$repo_root/scripts/ios/verify-notification-privacy-policy.sh"
"$repo_root/scripts/ios/validate-notification-matrix.sh" --allow-pending "$repo_root/docs/xauxat/ios-notification-test-matrix.json"
pod install --project-directory="$repo_root/apps/ios" --deployment

build_settings=$(xcodebuild \
  -workspace "$workspace" \
  -scheme "$scheme" \
  -configuration Release \
  -showBuildSettings \
  XAUXAT_DEVELOPMENT_TEAM="$team_id")
version=$(awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / {print $2; exit}' <<<"$build_settings")
build=$(awk -F ' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION = / {print $2; exit}' <<<"$build_settings")
test -n "$version"
test -n "$build"

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
archive_path="$output_dir/XauXat-$version-$build.xcarchive"
export_path="$output_dir/XauXat-$version-$build"

if [[ -e "$archive_path" || -e "$export_path" ]]; then
  echo "Release output already exists for XauXat $version ($build): $output_dir" >&2
  echo "Choose a new --output-dir or move the previous release output first." >&2
  exit 1
fi

xcodebuild \
  -quiet \
  -workspace "$workspace" \
  -scheme "$scheme" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  XAUXAT_DEVELOPMENT_TEAM="$team_id" \
  archive

archive_app="$archive_path/Products/Applications/SimpleX.app"
"$repo_root/scripts/ios/verify-xauxat-identifiers.sh" "$archive_app"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/xauxat-testflight.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

signed_entitlements() {
  local bundle_path=$1
  local output_path=$2
  codesign -d --entitlements :- "$bundle_path" >"$output_path" 2>/dev/null
  plutil -lint "$output_path" >/dev/null
}

assert_entitlement() {
  local entitlements_path=$1
  local key_path=$2
  local expected=$3
  local label=$4
  local actual
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key_path" "$entitlements_path")
  if [[ "$actual" != "$expected" ]]; then
    echo "$label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

assert_entitlement_absent() {
  local entitlements_path=$1
  local key_path=$2
  local label=$3
  if /usr/libexec/PlistBuddy -c "Print :$key_path" "$entitlements_path" >/dev/null 2>&1; then
    echo "$label must not be present in this distribution build" >&2
    exit 1
  fi
}

verify_signed_entitlements() {
  local app_path=$1
  local expected_apns=${2:-}
  local main_entitlements="$work_dir/main-entitlements.plist"
  local nse_entitlements="$work_dir/nse-entitlements.plist"
  local share_entitlements="$work_dir/share-entitlements.plist"

  signed_entitlements "$app_path" "$main_entitlements"
  signed_entitlements "$app_path/PlugIns/SimpleX NSE.appex" "$nse_entitlements"
  signed_entitlements "$app_path/PlugIns/SimpleX SE.appex" "$share_entitlements"

  assert_entitlement "$main_entitlements" "application-identifier" "$team_id.pt.exsoria.xauxat" "main application identifier"
  if [[ -n "$expected_apns" ]]; then
    assert_entitlement "$main_entitlements" "aps-environment" "$expected_apns" "APNs environment"
  fi
  assert_entitlement_absent "$main_entitlements" "com.apple.developer.networking.multicast" "Multicast Networking"
  assert_entitlement "$main_entitlements" "com.apple.security.application-groups:0" "group.pt.exsoria.xauxat" "main App Group"
  assert_entitlement "$main_entitlements" "keychain-access-groups:0" "$team_id.pt.exsoria.xauxat" "main keychain group"

  assert_entitlement "$nse_entitlements" "application-identifier" "$team_id.pt.exsoria.xauxat.notification-service" "NSE application identifier"
  assert_entitlement "$nse_entitlements" "com.apple.security.application-groups:0" "group.pt.exsoria.xauxat" "NSE App Group"
  assert_entitlement "$nse_entitlements" "keychain-access-groups:0" "$team_id.pt.exsoria.xauxat" "NSE keychain group"

  assert_entitlement "$share_entitlements" "application-identifier" "$team_id.pt.exsoria.xauxat.share" "share application identifier"
  assert_entitlement "$share_entitlements" "com.apple.security.application-groups:0" "group.pt.exsoria.xauxat" "share App Group"
  assert_entitlement "$share_entitlements" "keychain-access-groups:0" "$team_id.pt.exsoria.xauxat" "share keychain group"
}

verify_signed_entitlements "$archive_app"

export_options="$work_dir/ExportOptions.plist"
cp "$export_options_source" "$export_options"
/usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$export_options"
xcodebuild \
  -quiet \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates

ipa_path=$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print -quit)
test -n "$ipa_path"
unzip -q "$ipa_path" -d "$work_dir/ipa"
exported_app=$(find "$work_dir/ipa/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)
test -n "$exported_app"
"$repo_root/scripts/ios/verify-xauxat-identifiers.sh" "$exported_app" production
verify_signed_entitlements "$exported_app" production

swiftygif_privacy_manifest=$(find "$exported_app/Frameworks" -path '*SwiftyGif*.framework/*/PrivacyInfo.xcprivacy' -type f -print -quit)
if [[ -z "$swiftygif_privacy_manifest" ]]; then
  echo "The exported app is missing SwiftyGif's required PrivacyInfo.xcprivacy manifest." >&2
  exit 1
fi
plutil -lint "$swiftygif_privacy_manifest" >/dev/null

echo "Exported TestFlight IPA: $ipa_path"

if [[ "$upload" == true ]]; then
  upload_options="$work_dir/UploadOptions.plist"
  cp "$export_options" "$upload_options"
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$upload_options"
  xcodebuild \
    -quiet \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$work_dir/upload" \
    -exportOptionsPlist "$upload_options" \
    -allowProvisioningUpdates
  echo "Uploaded XauXat $version ($build) to App Store Connect."
fi

echo "Archive: $archive_path"
