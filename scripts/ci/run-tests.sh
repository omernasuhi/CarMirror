#!/bin/bash
# Uygulamayı derler ve testleri verilen simülatörde çalıştırır.
# Kullanım: scripts/ci/run-tests.sh <simülatör-udid>
set -euo pipefail

UDID="$1"
OUT=build/test
rm -rf "$OUT"
mkdir -p "$OUT"

set +e
xcodebuild test \
  -project CarMirror.xcodeproj \
  -scheme CarMirror \
  -destination "id=$UDID" \
  -resultBundlePath "$OUT/TestResults.xcresult" \
  > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
set -e

echo "---- Derleme hataları ve uyarıları ----"
grep -E "(error|warning): " "$OUT/xcodebuild.log" | grep -v "^ld: warning" | sort -u | head -150 || true
echo "---- Test sonuçları ----"
grep -E "Test Case .*(passed|failed|skipped)|error: .*XCT|Executed [0-9]+ test|\*\* (BUILD|TEST) " "$OUT/xcodebuild.log" | tail -150 || true
echo "---- Tanılama ----"
grep -E "CarMirror: " "$OUT/xcodebuild.log" | head -40 || true

if [ "$STATUS" -ne 0 ]; then
  echo "---- xcodebuild çıktısının sonu ----"
  tail -150 "$OUT/xcodebuild.log"
fi
exit "$STATUS"
