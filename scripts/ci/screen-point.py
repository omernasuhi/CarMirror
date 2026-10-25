#!/usr/bin/env python3
"""CarPlay ekran görüntüsündeki bir pikseli Mac ekranındaki noktaya çevirir.

Kullanım: screen-point.py <pencere-bilgisi-dosyası> <görüntü.png> <piksel-x> <piksel-y>

Pencere bilgisi carplay-window.applescript çıktısıdır. CarPlay görüntüsünü
gösteren alan, en-boy oranı ekran görüntüsüne uyan en büyük arayüz öğesidir;
bulunamazsa pencerenin genişliği kullanılır ve aradaki yükseklik farkı başlık
çubuğu sayılır.
"""
import struct
import sys


def image_size(path):
    with open(path, "rb") as handle:
        header = handle.read(24)
    return struct.unpack(">II", header[16:24])


def main():
    info_path, image_path, px, py = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    image_width, image_height = image_size(image_path)
    aspect = image_width / image_height

    window = None
    elements = []
    with open(info_path) as handle:
        for line in handle:
            parts = line.split()
            if len(parts) >= 5 and parts[0] in ("WINDOW", "ELEMENT"):
                rect = tuple(float(value) for value in parts[1:5])
                if parts[0] == "WINDOW":
                    window = rect
                else:
                    elements.append(rect)
    if window is None:
        sys.exit("pencere bilgisi yok")

    wx, wy, ww, wh = window
    content = None
    for rect in sorted(elements, key=lambda r: r[2] * r[3], reverse=True):
        x, y, w, h = rect
        inside = x >= wx - 1 and y >= wy - 1 and x + w <= wx + ww + 1 and y + h <= wy + wh + 1
        if inside and h > 0 and abs(w / h - aspect) / aspect < 0.04 and w * h > 0.3 * ww * wh:
            content = rect
            break
    if content is None:
        scale = ww / image_width
        content = (wx, wy + max(0.0, wh - image_height * scale), ww, image_height * scale)
        print("içerik alanı tahmin edildi", content, file=sys.stderr)
    else:
        print("içerik alanı arayüz öğesinden alındı", content, file=sys.stderr)

    cx, cy, cw, ch = content
    print(f"{cx + px * cw / image_width:.0f} {cy + py * ch / image_height:.0f}")


if __name__ == "__main__":
    main()
