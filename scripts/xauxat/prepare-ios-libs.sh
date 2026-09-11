#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CONFIG_FILE="$SCRIPT_DIR/ios-libs.env"

if [ ! -f "$REPO_ROOT/apps/ios/SimpleX.xcodeproj/project.pbxproj" ] ||
   [ ! -f "$REPO_ROOT/simplex-chat.cabal" ]; then
  echo "Error: XauXat repository root could not be validated." >&2
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: missing $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

ARCHIVE_DIR=""
if [ "${1:-}" = "--archive-dir" ]; then
  if [ -z "${2:-}" ] || [ "${3:-}" != "" ]; then
    echo "Usage: $0 [--archive-dir /absolute/or/relative/path]" >&2
    exit 1
  fi
  ARCHIVE_DIR=$(CDPATH= cd -- "$2" && pwd)
elif [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--archive-dir /absolute/or/relative/path]" >&2
  exit 1
fi

MAC2IOS_BIN=${MAC2IOS_BIN:-}
if [ -z "$MAC2IOS_BIN" ]; then
  MAC2IOS_BIN=$(command -v mac2ios || true)
fi
if [ -z "$MAC2IOS_BIN" ] || [ ! -x "$MAC2IOS_BIN" ]; then
  echo "Error: mac2ios is required. Set MAC2IOS_BIN or add it to PATH." >&2
  exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xauxat-ios-libs.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

ARM_ARCHIVE="$WORK_DIR/pkg-ios-aarch64-swift-json.zip"
X86_ARCHIVE="$WORK_DIR/pkg-ios-x86_64-swift-json.zip"

if [ -n "$ARCHIVE_DIR" ]; then
  cp "$ARCHIVE_DIR/pkg-ios-aarch64-swift-json.zip" "$ARM_ARCHIVE"
  cp "$ARCHIVE_DIR/pkg-ios-x86_64-swift-json.zip" "$X86_ARCHIVE"
else
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    --output "$ARM_ARCHIVE" "$XAUXAT_IOS_ARM64_URL"
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    --output "$X86_ARCHIVE" "$XAUXAT_IOS_X86_64_URL"
fi

verify_archive() {
  expected_hash=$1
  archive_path=$2
  actual_hash=$(shasum -a 256 "$archive_path" | awk '{print $1}')
  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "Error: checksum mismatch for $(basename "$archive_path")" >&2
    echo "Expected: $expected_hash" >&2
    echo "Actual:   $actual_hash" >&2
    exit 1
  fi
  unzip -tq "$archive_path" >/dev/null
}

verify_archive "$XAUXAT_IOS_ARM64_SHA256" "$ARM_ARCHIVE"
verify_archive "$XAUXAT_IOS_X86_64_SHA256" "$X86_ARCHIVE"

RAW_ARM="$WORK_DIR/raw-aarch64"
RAW_X86="$WORK_DIR/raw-x86_64"
PREPARED="$WORK_DIR/prepared"
mkdir -p "$RAW_ARM" "$RAW_X86" \
  "$PREPARED/mac-aarch64" "$PREPARED/mac-x86_64" \
  "$PREPARED/ios" "$PREPARED/sim"

unzip -q "$ARM_ARCHIVE" -d "$RAW_ARM"
unzip -q "$X86_ARCHIVE" -d "$RAW_X86"

for raw_dir in "$RAW_ARM" "$RAW_X86"; do
  archive_count=$(find "$raw_dir" -maxdepth 1 -type f -name '*.a' | wc -l | tr -d ' ')
  if [ "$archive_count" -ne 5 ]; then
    echo "Error: expected 5 static libraries in $raw_dir, found $archive_count." >&2
    exit 1
  fi
done

cp "$RAW_ARM"/*.a "$PREPARED/mac-aarch64/"
cp "$RAW_X86"/*.a "$PREPARED/mac-x86_64/"
cp "$RAW_ARM"/*.a "$PREPARED/ios/"
cp "$RAW_X86"/*.a "$PREPARED/sim/"
chmod u+w "$PREPARED"/*/*.a

MAC2IOS_LOG="$WORK_DIR/mac2ios.log"
run_mac2ios() {
  if ! "$@" >>"$MAC2IOS_LOG" 2>&1; then
    echo "Error: mac2ios failed. Last output:" >&2
    tail -80 "$MAC2IOS_LOG" >&2
    exit 1
  fi
}

for library in "$PREPARED/ios"/*.a; do
  run_mac2ios "$MAC2IOS_BIN" "$library"
done
for library in "$PREPARED/sim"/*.a; do
  run_mac2ios "$MAC2IOS_BIN" -s "$library"
done

LIBRARIES_DIR="$REPO_ROOT/apps/ios/Libraries"
mkdir -p "$LIBRARIES_DIR"
for platform_dir in mac-aarch64 mac-x86_64 ios sim; do
  target_dir="$LIBRARIES_DIR/$platform_dir"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp "$PREPARED/$platform_dir"/*.a "$target_dir/"
done

(
  cd "$REPO_ROOT"
  ./scripts/ios/update-pbxproj.sh
)

echo "Prepared SimpleX ${XAUXAT_SIMPLEX_BASELINE} libraries with verified checksums."
echo "Device libraries:    $LIBRARIES_DIR/ios"
echo "Simulator libraries: $LIBRARIES_DIR/sim"
