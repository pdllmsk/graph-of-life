#!/bin/zsh
# Рисует AppIcon.icns: красный квадрат со скруглением и чёрная черта, по сетке значков macOS.
#   ./make-icon.sh [цвет фона, hex]
set -euo pipefail
cd "$(dirname "$0")"
BG=${1:-EE0000}
TMP=$(mktemp -d)
cat > "$TMP/icon.swift" <<'SWIFT'
import AppKit
let hex = Int(CommandLine.arguments[1], radix: 16)!
let bg = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                 blue: CGFloat(hex & 255) / 255, alpha: 1)
// Черта в координатах исходной картинки 640×640, y вниз.
let stripe: [(CGFloat, CGFloat)] = [(0, 620), (320, 300), (320, 340), (20, 640), (0, 640)]
// Рисуем в sRGB, иначе цвета сдвигаются под профиль экрана.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                           .retagging(with: .sRGB)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).addClip()
bg.setFill(); body.fill()
let k = body.width / 640
let shape = NSBezierPath()
for (i, p) in stripe.enumerated() {
    let q = NSPoint(x: body.minX + p.0 * k, y: body.maxY - p.1 * k)
    if i == 0 { shape.move(to: q) } else { shape.line(to: q) }
}
shape.close()
NSColor.black.setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT
swiftc "$TMP/icon.swift" -o "$TMP/icon"
"$TMP/icon" "$BG" "$TMP/1024.png"
mkdir "$TMP/AppIcon.iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$TMP/1024.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$TMP/1024.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o AppIcon.icns
rm -rf "$TMP"
echo "Готово: AppIcon.icns, фон #$BG"
