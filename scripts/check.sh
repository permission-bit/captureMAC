#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check-localizations.py
cargo fmt -- --check
cargo test --offline
cargo clippy --offline --all-targets -- -D warnings
./scripts/build.sh debug
swiftc -swift-version 5 -parse-as-library -Onone \
  -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$PWD/target/swift-cache" \
  -import-objc-header native/StillCore.h \
  native/Localization.swift native/Conversion.swift native/CaptureModel.swift native/Views.swift tests/NativeSmoke.swift \
  -L target/debug -lstill_core \
  -framework SwiftUI -framework AppKit -framework ScreenCaptureKit \
  -framework AVFoundation -framework AVKit \
  -o build/native-smoke
./build/native-smoke "$PWD/build/previews" "$PWD/build/Still.app/Contents/Resources"
plutil -lint build/Still.app/Contents/Info.plist
codesign --verify --strict build/Still.app

swiftc -swift-version 5 -parse-as-library -Onone \
  -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$PWD/target/swift-cache" \
  -import-objc-header native/StillCore.h \
  native/Localization.swift native/Conversion.swift native/CaptureModel.swift tests/ConversionSmoke.swift \
  -L target/debug -lstill_core -framework SwiftUI -framework AppKit \
  -framework ScreenCaptureKit -framework AVFoundation -o build/conversion-smoke
./build/conversion-smoke "$PWD/build/conversion-tests"
