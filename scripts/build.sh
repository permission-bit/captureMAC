#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-release}"
if [[ "$MODE" != "debug" && "$MODE" != "release" ]]; then
  echo "Usage: scripts/build.sh [debug|release]" >&2
  exit 2
fi
export MACOSX_DEPLOYMENT_TARGET=15.0
export CLANG_MODULE_CACHE_PATH="$PWD/target/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/target/swift-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"
if [[ "$MODE" == "release" ]]; then
  cargo build --release --offline
  SWIFT_OPT=(-O)
else
  cargo build --offline
  SWIFT_OPT=(-Onone -g)
fi
APP="$PWD/build/Still.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp native/Info.plist "$APP/Contents/Info.plist"
cp -R native/Resources/*.lproj "$APP/Contents/Resources/"
swiftc -swift-version 5 -parse-as-library "${SWIFT_OPT[@]}" \
  -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -import-objc-header native/StillCore.h \
  native/Localization.swift native/Conversion.swift native/CaptureModel.swift native/Views.swift native/StillApp.swift \
  -L "target/$MODE" -lstill_core \
  -framework SwiftUI -framework AppKit -framework ScreenCaptureKit \
  -framework AVFoundation -framework AVKit -framework Carbon \
  -o "$APP/Contents/MacOS/Still"
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  swift -module-cache-path "$SWIFT_MODULECACHE_PATH" scripts/make-icon.swift build/AppIcon.iconset
  python3 scripts/pack-icon.py build/AppIcon.iconset build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGNING_IDENTITY:--}" --entitlements native/Still.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
