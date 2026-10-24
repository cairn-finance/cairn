#!/bin/sh
set -eu

repo_root=${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must provide CI_PRIMARY_REPOSITORY_PATH}
cd "$repo_root"

team_id=${DEVELOPMENT_TEAM:-${CI_TEAM_ID:-}}
bundle_id=${PRODUCT_BUNDLE_IDENTIFIER:-${CI_BUNDLE_ID:-}}
container_id=${ICLOUD_CONTAINER_ID:-}

check_identifier() {
  case "$2" in
    ''|*[!A-Za-z0-9.-]*)
      printf 'error: %s must be a nonempty identifier containing only letters, numbers, dots, and hyphens.\n' "$1" >&2
      exit 1
      ;;
  esac
}

check_identifier 'CI_TEAM_ID (or DEVELOPMENT_TEAM)' "$team_id"
check_identifier 'CI_BUNDLE_ID (or PRODUCT_BUNDLE_IDENTIFIER)' "$bundle_id"
# Existing installs must keep using their registered container, which may not
# be derived from the bundle identifier. Require it instead of guessing.
check_identifier ICLOUD_CONTAINER_ID "$container_id"

xcodebuild -version
sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
if ! awk -v version="$sdk_version" 'BEGIN {
  split(version, parts, ".")
  exit !(parts[1] > 27 || (parts[1] == 27 && parts[2] >= 1))
}'; then
  printf '%s\n' 'error: Select Xcode 27.1 or later in the Xcode Cloud workflow Environment; Cairn requires the iOS 27.1 SDK.' >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
fi

umask 077
printf 'DEVELOPMENT_TEAM = %s\nCAIRN_HOST_BUNDLE_IDENTIFIER = %s\nICLOUD_CONTAINER_ID = %s\n' \
  "$team_id" "$bundle_id" "$container_id" > Config/Signing.local.xcconfig

xcodegen generate
if [ ! -f Cairn.xcodeproj/project.pbxproj ]; then
  printf '%s\n' 'error: XcodeGen did not create Cairn.xcodeproj/project.pbxproj.' >&2
  exit 1
fi
