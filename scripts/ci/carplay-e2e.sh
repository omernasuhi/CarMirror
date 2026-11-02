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

carplay_shot() {
  xcrun simctl io "$UDID" screenshot --display=external "$1" > /dev/null
}

# Uygulamayı verilen etiketle başlatır; stdout/stderr (NSLog) dosyaya yazılır.
launch_app() {
  local label="$1"
  shift
  xcrun simctl launch --stdout="$PWD/$OUT/app-$label.stdout.log" --stderr="$PWD/$OUT/app-$label.stderr.log" "$UDID" "$BUNDLE_ID" "$@"
}

# CarPlay ana ekranında mı? ("Messages" etiketi görünüyorsa)
carplay_shows_home() {
  carplay_shot "$OUT/tmp-home-check.png"
  "$TOOLS/find-text" "$OUT/tmp-home-check.png" "Messages" > /dev/null 2>&1
}

# Daha önce bulunan simge konumuna dokunarak CarMirror'ı CarPlay'de açar.
open_on_carplay() {
  local attempt
  for attempt in 1 2 3; do
    if [ "$attempt" = 2 ]; then
      "$TOOLS/click" "$CX" "$CY" || true
    else
      osascript "$SCRIPTS/click-at.applescript" "$CX" "$CY" || true
    fi
    sleep 8
    if ! carplay_shows_home; then
      return 0
    fi
    log "CarPlay hâlâ ana ekranda; yeniden dokunuluyor ($attempt)"
  done
  return 1
}

collect_logs() {
  xcrun simctl spawn "$UDID" log show --last 15m --style compact \
    --predicate 'process == "CarMirror" OR eventMessage CONTAINS "CarMirror"' > "$OUT/app.log" 2>&1 || true
  xcrun simctl spawn "$UDID" log show --last 15m --style compact \
    --predicate '(process == "CarPlayTemplateUIHost" OR process == "CarPlay") AND (messageType == error OR messageType == fault)' \
    > "$OUT/carplay-system.log" 2>&1 || true
  xcrun simctl spawn "$UDID" log show --last 15m --style compact \
    --predicate 'eventMessage CONTAINS "carmirror-carplay-shim"' > "$OUT/carplay-shim-runtime.log" 2>&1 || true
  grep "carmirror-carplay-shim" "$OUT/carplay-shim-runtime.log" | tail -5 || true
  screencapture -x "$OUT/mac-desktop.png" 2>/dev/null || true
  mkdir -p "$OUT/crashes"
  find "$HOME/Library/Logs/DiagnosticReports" -name '*.ips' -newer "$OUT/build.log" 2>/dev/null \
    | grep -E "CarPlay|CarMirror" | while read -r report; do cp "$report" "$OUT/crashes/"; done || true
  if ls "$OUT"/crashes/*.ips > /dev/null 2>&1; then
    log "Çökme raporları:"
    python3 "$SCRIPTS/summarize-crashes.py" "$OUT"/crashes/*.ips | tee "$OUT/crashes/summary.txt" || true
  fi
}
trap collect_logs EXIT

log "Yardımcı araçlar derleniyor"
TOOLS=build/tools
mkdir -p "$TOOLS"
xcrun swiftc -O -o "$TOOLS/find-text" "$SCRIPTS/find-text.swift"
xcrun swiftc -O -o "$TOOLS/click" "$SCRIPTS/click.swift"

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
launch_app demo1 -CarMirrorTab demo
sleep 6
xcrun simctl io "$UDID" screenshot "$OUT/1-iphone.png" > /dev/null

log "CarPlay simülatör yaması yükleniyor (Xcode'da Run öncesi kendiliğinden çalışır)"
PLATFORM_NAME=iphonesimulator scripts/carplay-sim-shim/install.sh "$UDID"
cp /tmp/carmirror-carplay-shim.log "$OUT/carplay-shim.log" 2> /dev/null || true

log "CarPlay ekranı bağlanıyor"
osascript "$SCRIPTS/enable-carplay.applescript" 2>&1 | tee "$OUT/enable-carplay.log"
sleep 12

osascript "$SCRIPTS/carplay-window.applescript" > "$OUT/carplay-window.txt" 2> "$OUT/carplay-window.log"
cat "$OUT/carplay-window.log"
log "CarPlay penceresi ve öğeleri:"
head -40 "$OUT/carplay-window.txt"
sleep 2
carplay_shot "$OUT/2-carplay-home.png"
xcrun simctl io "$UDID" screenshot "$OUT/2-iphone-after-carplay.png" > /dev/null

if ! LABEL=$("$TOOLS/find-text" "$OUT/2-carplay-home.png" "CarMirror" 2> "$OUT/ocr-home.log"); then
  cat "$OUT/ocr-home.log"
  log "HATA: CarPlay ana ekranında CarMirror simgesi bulunamadı"
  exit 1
fi
log "CarMirror etiketi (x y üst yükseklik, piksel): $LABEL"
read -r LX LY LTOP LH <<< "$LABEL"
ICON_Y=$(python3 -c "print($LTOP - 1.8 * $LH)")

screen_point() {
  python3 "$SCRIPTS/screen-point.py" "$OUT/carplay-window.txt" "$OUT/2-carplay-home.png" "$1" "$2"
}

mirrored=false
attempt=0
# Önce System Events ile, olmazsa doğrudan fare olayıyla; her birinde önce
# simgenin ortasına, sonra etiketin üzerine dokun.
for method in system-events cgevent; do
  for target_y in "$ICON_Y" "$LY"; do
    attempt=$((attempt + 1))
    read -r CX CY <<< "$(screen_point "$LX" "$target_y")"
    log "Deneme $attempt ($method): CarPlay'de CarMirror'a dokunuluyor: $CX,$CY"
    if [ "$method" = system-events ]; then
      osascript "$SCRIPTS/click-at.applescript" "$CX" "$CY" || true
    else
      "$TOOLS/click" "$CX" "$CY" || true
    fi
    sleep 1
    screencapture -x -C "$OUT/click-$attempt-mac.png" 2> /dev/null || true
    sleep 9
    carplay_shot "$OUT/3-carplay-mirroring.png"
    if "$TOOLS/find-text" "$OUT/3-carplay-mirroring.png" "CARMIRROR DEMO" > /dev/null 2> "$OUT/ocr-mirroring.log"; then
      mirrored=true
      break 2
    fi
    cat "$OUT/ocr-mirroring.log"
  done
done

xcrun simctl io "$UDID" screenshot "$OUT/4-iphone.png" > /dev/null
if [ "$mirrored" != true ]; then
  log "HATA: CarPlay ekranında telefonun Demo ekranı görünmedi"
  exit 1
fi

log "Asistan ekranı CarPlay'de deneniyor"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2> /dev/null || true
sleep 2
launch_app assistant -CarMirrorTab assistant -CarMirrorAssistantDemo YES
sleep 8
open_on_carplay || log "UYARI: CarMirror CarPlay'de açılamadı (asistan adımı)"
sleep 4
carplay_shot "$OUT/6-carplay-assistant.png"
xcrun simctl io "$UDID" screenshot "$OUT/6-iphone-assistant.png" > /dev/null
ASSISTANT_NAME=$(python3 -c "print('ALFRED')")
if "$TOOLS/find-text" "$OUT/6-carplay-assistant.png" "$ASSISTANT_NAME" > /dev/null 2> "$OUT/ocr-assistant.log"; then
  log "Asistan CarPlay ekranında görünüyor"
else
  log "UYARI: asistan adı CarPlay ekran görüntüsünde okunamadı (OCR); görüntülere bakın"
  head -20 "$OUT/ocr-assistant.log" || true
fi

log "Navigasyon CarPlay'de deneniyor"
xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" 2> /dev/null || true
xcrun simctl location "$UDID" set 41.0369,28.9850 2> /dev/null || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2> /dev/null || true
sleep 2
launch_app navigation -CarMirrorTab assistant -CarMirrorAssistantDemo YES -CarMirrorDemoDestination "Kadıköy İskelesi"
sleep 8
open_on_carplay || log "UYARI: CarMirror CarPlay'de açılamadı (navigasyon adımı)"
sleep 16
carplay_shot "$OUT/7-carplay-navigation.png"
xcrun simctl io "$UDID" screenshot "$OUT/7-iphone-navigation.png" > /dev/null
navigation_seen=false
for needle in kilometre dakika km min; do
  if "$TOOLS/find-text" "$OUT/7-carplay-navigation.png" "$needle" > /dev/null 2> "$OUT/ocr-navigation.log"; then
    navigation_seen=true
    break
  fi
done
if [ "$navigation_seen" = true ]; then
  log "Navigasyon CarPlay ekranında görünüyor"
else
  log "UYARI: navigasyon metni CarPlay ekran görüntüsünde okunamadı (OCR); görüntülere bakın"
  head -20 "$OUT/ocr-navigation.log" || true
fi

log "Demo ekranına dönülüyor"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2> /dev/null || true
sleep 2
launch_app demo2 -CarMirrorTab demo
sleep 8
open_on_carplay || log "UYARI: CarMirror CarPlay'de açılamadı (demo adımı)"

log "CarPlay ekranı kaydediliyor"
xcrun simctl io "$UDID" recordVideo --display=external --codec=h264 --force "$OUT/carplay.mov" > /dev/null 2>&1 &
RECORDER=$!
sleep 8
# xcrun, simctl'i ayrı bir süreç olarak çalıştırabilir; kayıt sürecine doğrudan sinyal gönder.
pkill -INT -f "simctl io .* recordVideo" 2> /dev/null || kill -INT "$RECORDER" 2> /dev/null || true
for _ in $(seq 1 20); do
  kill -0 "$RECORDER" 2> /dev/null || break
  sleep 1
done
if kill -0 "$RECORDER" 2> /dev/null; then
  log "Kayıt kapanmadı; zorla durduruluyor"
  pkill -KILL -f "simctl io .* recordVideo" 2> /dev/null || true
  kill -KILL "$RECORDER" 2> /dev/null || true
fi
wait "$RECORDER" 2> /dev/null || true
carplay_shot "$OUT/5-carplay-mirroring-later.png"

log "BAŞARILI: iPhone ekranı CarPlay ekranında görünüyor"
