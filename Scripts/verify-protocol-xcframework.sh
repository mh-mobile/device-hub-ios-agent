#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PROCESS_GUARD="$REPOSITORY_ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard verify-protocol-xcframework 600 "$0" "$@"

readonly SOURCE_HEADERS="$REPOSITORY_ROOT/Rust/DeviceHubFFI/include"
readonly SMOKE_SOURCE="$REPOSITORY_ROOT/Rust/DeviceHubFFI/tests/ffi_smoke.c"
readonly XCFRAMEWORK="${1:-$REPOSITORY_ROOT/Rust/Artifacts/DeviceHubFFI.xcframework}"
readonly DEVICE_SLICE="$XCFRAMEWORK/ios-arm64"
readonly SIMULATOR_SLICE="$XCFRAMEWORK/ios-arm64-simulator"
readonly LIBRARY_NAME="libdevice_hub_ffi.a"
readonly EXPECTED_MINIMUM="26.0"

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "error: XCFramework does not exist: $XCFRAMEWORK" >&2
  exit 1
fi
if ! /usr/bin/plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null; then
  echo "error: invalid XCFramework Info.plist" >&2
  exit 1
fi

for slice in "$DEVICE_SLICE" "$SIMULATOR_SLICE"; do
  if [[ ! -s "$slice/$LIBRARY_NAME" ]]; then
    echo "error: missing static library: $slice/$LIBRARY_NAME" >&2
    exit 1
  fi
  for header in device_hub_ffi.h module.modulemap; do
    if ! cmp -s "$SOURCE_HEADERS/$header" "$slice/Headers/$header"; then
      echo "error: packaged $header does not match the reviewed source" >&2
      exit 1
    fi
  done
done

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

# Prints each object in a static library built for another platform, or for
# a newer OS than the slice promises. Older minimums (prebuilt standard
# library objects) are fine. The smoke executable below cannot catch this:
# its own minimum comes from the flag passed to clang.
library_version_violations() {
  local library="$1"
  local build_platform="$2"
  local version_min_command="$3"
  local maximum="$4"
  /usr/bin/otool -l "$library" | awk \
    -v platform="$build_platform" \
    -v version_min="$version_min_command" \
    -v maximum="$maximum" '
    function number(version, parts) {
      split(version, parts, ".")
      return parts[1] * 10000 + parts[2] * 100 + parts[3]
    }
    /^[^ ].*\.o\)?:$/ { object = substr($0, 1, length($0) - 1) }
    $1 == "cmd" { command = $2; next }
    command == "LC_BUILD_VERSION" && $1 == "platform" && $2 != platform {
      print object ": platform " $2
    }
    command == "LC_BUILD_VERSION" && $1 == "minos" && number($2) > number(maximum) {
      print object ": minos " $2
    }
    command ~ /^LC_VERSION_MIN_/ && command != version_min && $1 == "version" {
      print object ": " command
    }
    command == version_min && $1 == "version" && number($2) > number(maximum) {
      print object ": version " $2
    }
  '
}

verify_slice() {
  local sdk="$1"
  local minimum_flag="$2"
  local expected_platform="$3"
  local library="$4"
  local executable="$temporary_directory/smoke-$sdk"

  /usr/bin/xcrun --sdk "$sdk" clang \
    -arch arm64 \
    "$minimum_flag$EXPECTED_MINIMUM" \
    -Wall \
    -Wextra \
    -Werror \
    -I "$SOURCE_HEADERS" \
    "$SMOKE_SOURCE" \
    "$library" \
    -o "$executable"

  if ! file "$executable" | rg -q 'Mach-O 64-bit executable arm64'; then
    echo "error: $sdk smoke executable is not arm64 Mach-O" >&2
    exit 1
  fi

  local version_min_command="LC_VERSION_MIN_IPHONEOS"
  if [[ "$expected_platform" == 7 ]]; then
    version_min_command="LC_VERSION_MIN_IPHONESIMULATOR"
  fi
  local violations
  violations="$(library_version_violations \
    "$library" "$expected_platform" "$version_min_command" "$EXPECTED_MINIMUM")"
  if [[ -n "$violations" ]]; then
    echo "error: $sdk library has objects for another platform or a newer OS:" >&2
    echo "$violations" >&2
    exit 1
  fi

  local build_commands
  local platform
  local minimum
  build_commands="$(/usr/bin/otool -l "$executable")"
  platform="$(awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1; next }
    found && $1 == "platform" { print $2; exit }
  ' <<<"$build_commands")"
  minimum="$(awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1; next }
    found && $1 == "minos" { print $2; exit }
  ' <<<"$build_commands")"

  if [[ "$platform" != "$expected_platform" || "$minimum" != "$EXPECTED_MINIMUM" ]]; then
    echo "error: $sdk slice has platform=$platform minos=$minimum" >&2
    exit 1
  fi
}

verify_slice \
  iphoneos \
  -miphoneos-version-min= \
  2 \
  "$DEVICE_SLICE/$LIBRARY_NAME"
verify_slice \
  iphonesimulator \
  -mios-simulator-version-min= \
  7 \
  "$SIMULATOR_SLICE/$LIBRARY_NAME"

/usr/bin/xcrun --sdk iphonesimulator clang \
  -arch arm64 \
  -mios-simulator-version-min="$EXPECTED_MINIMUM" \
  -Wall \
  -Wextra \
  -Werror \
  -fsyntax-only \
  -I "$SOURCE_HEADERS" \
  "$SMOKE_SOURCE"

echo "Verified Device Hub XCFramework: arm64 iOS 26 + arm64 Simulator 26."
