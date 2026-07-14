import AppKit

// SF Symbol "sparkle", tinted with the piper-style gradient (cyan -> indigo).
// Native glyph instead of a hand-rolled star path — clean at any size.
func tintedSparkle(pointSize: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    guard let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    else { return NSImage(size: NSSize(width: pointSize, height: pointSize)) }

    let size = symbol.size
    let result = NSImage(size: size)
    result.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.setBlendMode(.sourceIn)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0x22/255, green: 0xd3/255, blue: 0xee/255, alpha: 1),
            NSColor(calibratedRed: 0x63/255, green: 0x66/255, blue: 0xf1/255, alpha: 1),
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -45)
    }
    result.unlockFocus()
    return result
}

// Rounded-square badge, piper-style gradient (cyan -> indigo) on dark navy bg,
// sparkle glyph (Claude mark) with a "%" tucked in the corner.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.22
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let bgGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0x0f/255, green: 0x17/255, blue: 0x2a/255, alpha: 1),
        NSColor(calibratedRed: 0x1e/255, green: 0x1b/255, blue: 0x4b/255, alpha: 1),
    ])
    bgGradient?.draw(in: bgPath, angle: -45)

    let strokeGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0x22/255, green: 0xd3/255, blue: 0xee/255, alpha: 1),
        NSColor(calibratedRed: 0x63/255, green: 0x66/255, blue: 0xf1/255, alpha: 1),
    ])
    ctx.saveGState()
    bgPath.addClip()
    strokeGradient?.draw(in: bgPath, angle: -45)
    ctx.restoreGState()

    // inner fill (slightly inset so the gradient stroke shows as a ring)
    let inset = size * 0.045
    let innerPath = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    bgGradient?.draw(in: innerPath, angle: -45)

    // sparkle (Claude glyph), centered slightly up-left
    let sparkle = tintedSparkle(pointSize: size * 0.36)
    sparkle.draw(at: CGPoint(x: size * 0.42 - sparkle.size.width / 2, y: size * 0.56 - sparkle.size.height / 2),
                 from: .zero, operation: .sourceOver, fraction: 1)

    // "%" glyph, bottom-right
    let pctSize = size * 0.24
    let pctFont = NSFont.monospacedSystemFont(ofSize: pctSize, weight: .bold)
    let pctAttrs: [NSAttributedString.Key: Any] = [
        .font: pctFont,
        .foregroundColor: NSColor(calibratedRed: 0xe2/255, green: 0xe8/255, blue: 0xf0/255, alpha: 1),
    ]
    let pctString = NSAttributedString(string: "%", attributes: pctAttrs)
    let pctBounds = pctString.size()
    pctString.draw(at: CGPoint(x: size - pctBounds.width - size * 0.16, y: size * 0.14))

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    savePNG(drawIcon(size: s), to: "\(outDir)/icon_\(Int(s)).png")
}
print("icons written to \(outDir)")
