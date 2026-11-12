// Подключается вместо последней строки main.swift (app.run()) и снимает окна приложения в RAW_DIR.
// Плашки снимаются с белой подложкой: размытие фона при такой отрисовке не работает.
let rawDir = ProcessInfo.processInfo.environment["RAW_DIR"]!
func snap(_ v: NSView, _ name: String) {
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: rawDir + "/" + name))
}
/// Окна снимаем через их слои: обычная отрисовка теряет стеклянный переключатель вкладок macOS 26.
func snapLayer(_ v: NSView, _ name: String) {
    let scale = v.window?.backingScaleFactor ?? 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    v.layer!.render(in: ctx)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: rawDir + "/" + name))
}
func find<T: NSView>(_ v: NSView, _ t: T.Type) -> T? { if let x = v as? T { return x }; for s in v.subviews { if let x = find(s, t) { return x } }; return nil }
func bubble() -> NSWindow { NSApp.windows.first { $0.level == .screenSaver && $0.isVisible && $0.contentView != nil }! }
func frameView(_ w: NSWindow) -> NSView { w.contentView!.superview ?? w.contentView! }
func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
func clickStar(_ v: StarRating, points: Int) {
    let i = (points - 1) / 2, step = v.starSize * 1.22
    let x = CGFloat(i) * step + (points % 2 == 1 ? v.starSize * 0.25 : v.starSize * 0.75)
    let p = v.convert(NSPoint(x: x, y: v.bounds.midY), to: nil)
    v.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
        windowNumber: v.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
}
func typeInBubble(_ s: String) { (bubble().firstResponder as? NSTextView)?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
after(1) {
  NSApp.appearance = NSAppearance(named: .aqua)
  delegate.updateLook { $0.tint = NSColor.white.withAlphaComponent(0.82) }
  delegate.perform(Selector(("showNow"))); after(0.8) { snap(bubble().contentView!, "phrase.png")
  delegate.perform(Selector(("rateNow"))); after(0.8) {
    let st = find(bubble().contentView!, StarRating.self)!; st.value = 7; st.display(); snap(bubble().contentView!, "rating.png")
    clickStar(st, points: 7); after(0.5) {
      typeInBubble("Выспался, утро спокойное"); after(0.3) { snap(bubble().contentView!, "comment.png")
      (bubble().firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
      delegate.perform(Selector(("openStats"))); after(1.5) {
        let sw = NSApp.windows.first { $0.title == "Статистика" && $0.isVisible }!
        sw.makeFirstResponder(nil)
        snapLayer(frameView(sw), "stats.png"); sw.close(); NSApp.deactivate()
        let t = Timer(timeInterval: 1, repeats: false) { _ in
          if let a = NSApp.windows.first(where: { $0.isVisible && $0.level == .modalPanel }) { snap(frameView(a), "about.png") }
          NSApp.stopModal(); NSApp.terminate(nil)
        }
        RunLoop.main.add(t, forMode: .common)
        delegate.perform(Selector(("openAbout")))
  } } } } } }
app.run()
