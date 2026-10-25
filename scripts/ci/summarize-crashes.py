#!/usr/bin/env python3
"""Çökme raporlarının (.ips) özetini yazdırır: süreç, istisna, uygulamaya özel
bilgi ve çöken iş parçacığının ilk çerçeveleri.

Kullanım: summarize-crashes.py <rapor.ips>...
"""
import json
import sys


def summarize(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        header_line = handle.readline()
        body_text = handle.read()
    try:
        header = json.loads(header_line)
        body = json.loads(body_text)
    except json.JSONDecodeError as error:
        print(f"{path}: okunamadı ({error})")
        return

    print(f"=== {header.get('app_name') or body.get('procName')} ({path.rsplit('/', 1)[-1]})")
    print("İstisna:", json.dumps(body.get("exception", {}), ensure_ascii=False))
    if body.get("termination"):
        print("Sonlandırma:", json.dumps(body["termination"], ensure_ascii=False)[:600])
    for key in ("asi", "lastExceptionBacktrace"):
        if key in body and key == "asi":
            print("Uygulamaya özel bilgi:", json.dumps(body[key], ensure_ascii=False)[:1500])

    images = body.get("usedImages", [])
    threads = body.get("threads", [])
    faulting = body.get("faultingThread", 0)
    frames = body.get("lastExceptionBacktrace") or (threads[faulting]["frames"] if faulting < len(threads) else [])
    print("Çöken iş parçacığı:" if not body.get("lastExceptionBacktrace") else "Son istisnanın çağrı yığını:")
    for index, frame in enumerate(frames[:25]):
        image = images[frame.get("imageIndex", 0)] if frame.get("imageIndex", 0) < len(images) else {}
        name = image.get("name", "?")
        symbol = frame.get("symbol", hex(frame.get("imageOffset", 0)))
        print(f"  {index:2d} {name:<32} {symbol}")


def main():
    for path in sys.argv[1:]:
        summarize(path)


if __name__ == "__main__":
    main()
