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
DEVICE_ONLY=false
LOCAL_BUILD=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive-dir)
      if [ -z "${2:-}" ]; then
        echo "Error: --archive-dir requires a path." >&2
        exit 1
      fi
      ARCHIVE_DIR=$(CDPATH= cd -- "$2" && pwd)
      shift 2
      ;;
    --device-only)
      DEVICE_ONLY=true
      shift
      ;;
    --local-build)
      LOCAL_BUILD=true
      shift
      ;;
    *)
      echo "Usage: $0 [--archive-dir /absolute/or/relative/path] [--device-only] [--local-build]" >&2
      exit 1
      ;;
  esac
done

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xauxat-ios-libs.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

ARM_ARCHIVE="$WORK_DIR/pkg-ios-aarch64-swift-json.zip"

if [ -n "$ARCHIVE_DIR" ]; then
  cp "$ARCHIVE_DIR/pkg-ios-aarch64-swift-json.zip" "$ARM_ARCHIVE"
else
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    --output "$ARM_ARCHIVE" "$XAUXAT_IOS_ARM64_URL"
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

if [ "$LOCAL_BUILD" = true ]; then
  unzip -tq "$ARM_ARCHIVE" >/dev/null
else
  verify_archive "$XAUXAT_IOS_ARM64_SHA256" "$ARM_ARCHIVE"
fi

RAW_ARM="$WORK_DIR/raw-aarch64"
PREPARED="$WORK_DIR/prepared"
mkdir -p "$RAW_ARM" "$PREPARED/mac-aarch64" "$PREPARED/ios"
if [ "$DEVICE_ONLY" = false ]; then
  mkdir -p "$PREPARED/sim"
fi

unzip -q "$ARM_ARCHIVE" -d "$RAW_ARM"

for raw_dir in "$RAW_ARM"; do
  archive_count=$(find "$raw_dir" -maxdepth 1 -type f -name '*.a' | wc -l | tr -d ' ')
  if [ "$archive_count" -ne 5 ]; then
    echo "Error: expected 5 static libraries in $raw_dir, found $archive_count." >&2
    exit 1
  fi
done

cp "$RAW_ARM"/*.a "$PREPARED/mac-aarch64/"
cp "$RAW_ARM"/*.a "$PREPARED/ios/"
chmod u+w "$PREPARED"/*/*.a
if [ "$DEVICE_ONLY" = false ]; then
  cp "$RAW_ARM"/*.a "$PREPARED/sim/"
  chmod u+w "$PREPARED/sim"/*.a
  SIMULATOR_SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
  for library in "$PREPARED/sim"/*.a; do
    python3 "$SCRIPT_DIR/convert-arm64-simulator-archive.py" \
      --sdk "$SIMULATOR_SDK_VERSION" \
      "$library"
  done
fi

LIBRARIES_DIR="$REPO_ROOT/apps/ios/Libraries"
mkdir -p "$LIBRARIES_DIR"
PLATFORM_DIRS="mac-aarch64 ios"
if [ "$DEVICE_ONLY" = false ]; then
  PLATFORM_DIRS="$PLATFORM_DIRS sim"
fi
for platform_dir in $PLATFORM_DIRS; do
  target_dir="$LIBRARIES_DIR/$platform_dir"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp "$PREPARED/$platform_dir"/*.a "$target_dir/"
done

(
  cd "$REPO_ROOT"
  ./scripts/ios/update-pbxproj.sh
)

if [ "$LOCAL_BUILD" = true ]; then
  echo "Prepared SimpleX libraries built from this XauXat source revision."
else
  echo "Prepared SimpleX ${XAUXAT_SIMPLEX_BASELINE} libraries with verified checksums."
fi
echo "Device libraries:    $LIBRARIES_DIR/ios"
if [ "$DEVICE_ONLY" = false ]; then
  echo "Simulator libraries: $LIBRARIES_DIR/sim"
fi
