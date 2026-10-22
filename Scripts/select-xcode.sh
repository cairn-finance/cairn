#!/bin/bash
set -euo pipefail

# iOS 27.1 enables iPhone Duo's full display and vertical system bars.
if [ -d /Applications/Xcode_27.1.app ]; then
  sudo -n xcode-select -s /Applications/Xcode_27.1.app
fi

xcodebuild -version
sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
if ! awk -v version="$sdk_version" 'BEGIN {
  split(version, parts, ".")
  exit !(parts[1] > 27 || (parts[1] == 27 && parts[2] >= 1))
}'; then
  echo "::error::Cairn requires the iOS 27.1 SDK or later for iPhone Duo. Selected SDK: $sdk_version"
  exit 1
fi
