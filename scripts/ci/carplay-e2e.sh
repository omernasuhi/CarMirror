#!/bin/bash
# CarPlay simülatöründe uçtan uca deneme:
# uygulamayı derler, iPhone simülatöründe Demo sekmesiyle açar, CarPlay
# ekranını bağlar, CarPlay ana ekranında CarMirror'a dokunur ve telefon
# ekranının CarPlay'e yansıdığını ekran görüntüsündeki yazıyla doğrular.
#
# Kullanım: scripts/ci/carplay-e2e.sh <simülatör-udid> [çıktı-klasörü]
# Xcode 26 ve öncesindeki Simulator.app gerekir (Xcode 27'de CarPlay ekranı yok).
set -euo pipefail

UDID="$1"
OUT="${2:-build/carplay}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
DERIVED=build/DerivedData
mkdir -p "$OUT"

log() { echo "==> $*"; }

image_size() {
  python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print(*struct.unpack(">II", d[16:24]))' "$1"
}

carplay_shot() {
  xcrun simctl io "$UDID" screenshot --display=external "$1" > /dev/null
}

collect_logs() {
  xcrun simctl spawn "$UDID" log show --last 5m --style compact \
    --predicate 'process == "CarMirror" OR eventMessage CONTAINS "CarMirror"' > "$OUT/app.log" 2>&1 || true
  screencapture -x "$OUT/mac-desktop.png" 2>/dev/null || true
}
trap collect_logs EXIT

log "Derleniyor"
if ! xcodebuild build -project CarMirror.xcodeproj -scheme CarMirror -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" > "$OUT/build.log" 2>&1; then
  grep -E "error: " "$OUT/build.log" | sort -u || true
  tail -60 "$OUT/build.log"
  exit 1
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/CarMirror.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
log "Uygulama: $BUNDLE_ID"
if grep -a -q "com.apple.developer.carplay-maps" "$APP/CarMirror"; then
  log "CarPlay yetkisi uygulamaya gömülü"
else
  log "UYARI: CarPlay yetkisi uygulamada bulunamadı"
fi

log "Simülatör açılıyor"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
open -a "$(xcode-select -p)/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID"
sleep 10

xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID" -CarMirrorTab demo
sleep 6
xcrun simctl io "$UDID" screenshot "$OUT/1-iphone.png" > /dev/null

log "CarPlay ekranı bağlanıyor"
osascript "$SCRIPTS/enable-carplay.applescript" 2>&1 | tee "$OUT/enable-carplay.log"
sleep 12

WINDOW=$(osascript "$SCRIPTS/carplay-window.applescript" 2> "$OUT/carplay-window.log")
cat "$OUT/carplay-window.log"
log "CarPlay penceresi (x y genişlik yükseklik): $WINDOW"
sleep 2
carplay_shot "$OUT/2-carplay-home.png"
xcrun simctl io "$UDID" screenshot "$OUT/2-iphone-after-carplay.png" > /dev/null

if ! LABEL=$(swift "$SCRIPTS/find-text.swift" "$OUT/2-carplay-home.png" "CarMirror" 2> "$OUT/ocr-home.log"); then
  cat "$OUT/ocr-home.log"
  log "HATA: CarPlay ana ekranında CarMirror simgesi bulunamadı"
  exit 1
fi
log "CarMirror etiketi (x y üst yükseklik, piksel): $LABEL"

read -r WX WY WW WH <<< "$WINDOW"
read -r IW IH <<< "$(image_size "$OUT/2-carplay-home.png")"
read -r LX LY LTOP LH <<< "$LABEL"

# Ekran görüntüsündeki pikseli ekrandaki noktaya çevirir. Pencerenin içeriği
# görüntüyle aynı en-boy oranında; aradaki fark pencere başlık çubuğudur.
screen_point() {
  python3 - "$WX" "$WY" "$WW" "$WH" "$IW" "$IH" "$1" "$2" <<'PY'
import sys
wx, wy, ww, wh, iw, ih, px, py = map(float, sys.argv[1:])
scale = ww / iw
titlebar = max(0.0, wh - ih * scale)
print(f"{wx + px * scale:.0f} {wy + titlebar + py * scale:.0f}")
PY
}

mirrored=false
# Önce simgenin ortasına, olmazsa etiketin üzerine dokun.
for target_y in "$(python3 -c "print($LTOP - 1.8 * $LH)")" "$LY"; do
  read -r CX CY <<< "$(screen_point "$LX" "$target_y")"
  log "CarPlay'de CarMirror'a dokunuluyor: $CX,$CY"
  swift "$SCRIPTS/click.swift" "$CX" "$CY"
  sleep 10
  carplay_shot "$OUT/3-carplay-mirroring.png"
  if swift "$SCRIPTS/find-text.swift" "$OUT/3-carplay-mirroring.png" "CARMIRROR DEMO" > /dev/null 2> "$OUT/ocr-mirroring.log"; then
    mirrored=true
    break
  fi
  cat "$OUT/ocr-mirroring.log"
done

xcrun simctl io "$UDID" screenshot "$OUT/4-iphone.png" > /dev/null
if [ "$mirrored" != true ]; then
  log "HATA: CarPlay ekranında telefonun Demo ekranı görünmedi"
  exit 1
fi

log "CarPlay ekranı kaydediliyor"
xcrun simctl io "$UDID" recordVideo --display=external --codec=h264 --force "$OUT/carplay.mov" > /dev/null 2>&1 &
RECORDER=$!
sleep 8
kill -INT "$RECORDER" 2> /dev/null || true
wait "$RECORDER" 2> /dev/null || true
carplay_shot "$OUT/5-carplay-mirroring-later.png"

log "BAŞARILI: iPhone ekranı CarPlay ekranında görünüyor"
