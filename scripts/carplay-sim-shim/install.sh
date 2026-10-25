#!/bin/bash
# iOS 26.4 / 26.5 simülatörlerindeki CarPlay hatasına geçici çözüm.
#
# Bu sürümlerin simülatöründe CarPlay'in sistem süreci (CarPlayTemplateUIHost),
# bir uygulama harita şablonu (CPMapTemplate) gösterdiği anda eksik bir yöntem
# yüzünden çöküyor; gerçek cihazlar etkilenmiyor. Bu betik eksik yöntemleri
# ekleyen küçük bir kütüphaneyi (carplay_sim_shim.m) derleyip simülatöre yükler.
#
# Xcode'da Run'a basınca CarMirror şemasının ön eylemi olarak kendiliğinden
# çalışır; sonucu /tmp/carmirror-carplay-shim.log dosyasına yazar.
#
# Elle çalıştırmak: scripts/carplay-sim-shim/install.sh [simülatör-udid]
#   (udid verilmezse açık olan simülatör kullanılır)
# Kaldırmak: xcrun simctl spawn booted launchctl unsetenv DYLD_INSERT_LIBRARIES

DEVICE="${1:-${TARGET_DEVICE_IDENTIFIER:-booted}}"
SOURCE="$(cd "$(dirname "$0")" && pwd)/carplay_sim_shim.m"
# launchctl setenv 127 karakterden uzun değerleri kestiği için kısa bir yol.
SHIM=/tmp/carmirror-carplay-shim.dylib
LOG=/tmp/carmirror-carplay-shim.log

build_shim() {
  if [ -f "$SHIM" ] && [ ! "$SOURCE" -nt "$SHIM" ]; then
    return 0
  fi
  local flags=(-sdk iphonesimulator clang -dynamiclib -mios-simulator-version-min=16.0 -framework Foundation)
  xcrun "${flags[@]}" -arch arm64 -arch x86_64 -o "$SHIM" "$SOURCE" \
    || xcrun "${flags[@]}" -arch arm64 -o "$SHIM" "$SOURCE"
}

apply_shim() {
  local device="$1" current
  current=$(xcrun simctl spawn "$device" launchctl getenv DYLD_INSERT_LIBRARIES 2> /dev/null)
  case ":$current:" in
    *":$SHIM:"*)
      echo "Yama zaten yüklü"
      ;;
    *)
      if xcrun simctl spawn "$device" launchctl setenv DYLD_INSERT_LIBRARIES "$SHIM${current:+:$current}"; then
        echo "Yama yüklendi"
        # Çalışan CarPlay süreci yamayı alsın diye yeniden başlatılır.
        pkill -f "CarPlayTemplateUIHost.app/CarPlayTemplateUIHost" 2> /dev/null || true
      else
        echo "Yama yüklenemedi"
      fi
      ;;
  esac
}

install_shim() {
  echo "---- $(date) cihaz: $DEVICE platform: ${PLATFORM_NAME:-?}"
  if [ -n "${PLATFORM_NAME:-}" ] && [ "$PLATFORM_NAME" != "iphonesimulator" ]; then
    echo "Simülatör değil; atlandı"
    return
  fi
  build_shim || { echo "Yama derlenemedi"; return; }

  if [ "$DEVICE" != "booted" ]; then
    xcrun simctl boot "$DEVICE" 2> /dev/null || true
    xcrun simctl bootstatus "$DEVICE" -b > /dev/null 2>&1 || true
    apply_shim "$DEVICE"
  elif xcrun simctl list devices booted 2> /dev/null | grep -q "(Booted)"; then
    apply_shim booted
  else
    # Xcode simülatörü bu betikten sonra açabilir; açıldığında yamayı uygula.
    echo "Açık simülatör yok; açılınca yüklenecek"
    nohup bash -c 'for _ in $(seq 1 150); do
        if xcrun simctl list devices booted 2> /dev/null | grep -q "(Booted)"; then
          sleep 5
          exec "$0" booted
        fi
        sleep 2
      done' "$0" > /dev/null 2>&1 &
  fi
}

install_shim >> "$LOG" 2>&1
tail -3 "$LOG"
exit 0
