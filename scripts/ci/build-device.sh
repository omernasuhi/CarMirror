#!/bin/bash
# Uygulamayı gerçek iPhone için (imzalamadan) derler; yalnızca cihazda
# derlenen kod yollarındaki hataları yakalamak içindir.
set -euo pipefail

OUT=build/device
mkdir -p "$OUT"
if ! xcodebuild build \
    -project CarMirror.xcodeproj \
    -scheme CarMirror \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    > "$OUT/xcodebuild.log" 2>&1; then
  grep -E "error: " "$OUT/xcodebuild.log" | sort -u || true
  tail -80 "$OUT/xcodebuild.log"
  exit 1
fi
grep -E "warning: .*\.swift" "$OUT/xcodebuild.log" | sort -u || true
echo "Gerçek iPhone derlemesi başarılı"
