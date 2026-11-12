// Собирает итоговые картинки: снимки окон на мягком фоне, со скруглением и тенью.
import AppKit
let raw = CommandLine.arguments[1], out = CommandLine.arguments[2]
func load(_ n: String) -> NSBitmapImageRep { NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: raw + "/" + n)))! }

/// items: снимок и радиус скругления в пикселях (окно 28, плашка 36 — это её 18 точек на Retina).
func compose(_ name: String, _ items: [(NSBitmapImageRep, CGFloat)], gap: CGFloat = 80, pad: CGFloat = 110) {
    let w = items.map { CGFloat($0.0.pixelsWide) }.reduce(0, +) + gap * CGFloat(items.count - 1) + pad * 2
    let h = items.map { CGFloat($0.0.pixelsHigh) }.max()! + pad * 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bg = NSRect(x: 0, y: 0, width: w, height: h)
    NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.84, green: 0.88, blue: 0.94, alpha: 1))!.draw(in: bg, angle: -60)
    var x = pad
    for (img, radius) in items {
        let r = NSRect(x: x, y: (h - CGFloat(img.pixelsHigh)) / 2, width: CGFloat(img.pixelsWide), height: CGFloat(img.pixelsHigh))
        let clip = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 60; shadow.shadowOffset = NSSize(width: 0, height: -24); shadow.set()
        NSColor.white.setFill(); clip.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); clip.addClip(); img.draw(in: r); NSGraphicsContext.restoreGraphicsState()
        x += r.width + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
}
compose("phrase.png", [(load("phrase.png"), 36)], pad: 140)
compose("rating.png", [(load("rating.png"), 36), (load("comment.png"), 36)])
compose("stats.png", [(load("stats.png"), 28)])
compose("about.png", [(load("about.png"), 28)])
