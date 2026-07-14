import AppKit

// Claude Code mark: https://github.com/anthropics/claude-code brand glyph,
// all straight edges (grid shape) with two evenodd cutouts. Original viewBox
// is 24x24 but content only spans y 5...20 (height 15) - we crop to that so
// the glyph isn't sitting in a box of empty padding.
func claudeCodeMarkPath(originX: CGFloat, originY: CGFloat, height: CGFloat) -> NSBezierPath {
    let scale = height / 15.0
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let yContent = y - 5
        return CGPoint(x: originX + x * scale, y: originY + (15 - yContent) * scale)
    }

    let path = NSBezierPath()
    path.windingRule = .evenOdd

    path.move(to: pt(20.998, 10.949))
    for p in [(24, 10.949), (24, 14.051), (21, 14.051), (21, 17.079), (19.513, 17.079),
              (19.513, 20), (18, 20), (18, 17.079), (16.513, 17.079), (16.513, 20),
              (15, 20), (15, 17.079), (9, 17.079), (9, 20), (7.488, 20), (7.488, 17.079),
              (6, 17.079), (6, 20), (4.487, 20), (4.487, 17.079), (3, 17.079), (3, 14.05),
              (0, 14.05), (0, 10.95), (3, 10.95), (3, 5), (20.998, 5), (20.998, 10.949)] {
        path.line(to: pt(CGFloat(p.0), CGFloat(p.1)))
    }
    path.close()

    path.move(to: pt(6, 10.949))
    for p in [(7.488, 10.949), (7.488, 8.102), (6, 8.102), (6, 10.949)] {
        path.line(to: pt(CGFloat(p.0), CGFloat(p.1)))
    }
    path.close()

    path.move(to: pt(16.51, 10.949))
    for p in [(18, 10.949), (18, 8.102), (16.51, 8.102), (16.51, 10.949)] {
        path.line(to: pt(CGFloat(p.0), CGFloat(p.1)))
    }
    path.close()

    return path
}

let markAspect: CGFloat = 24.0 / 15.0

func gradientMark(height: CGFloat) -> NSImage {
    let width = height * markAspect
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0x22/255, green: 0xd3/255, blue: 0xee/255, alpha: 1),
        NSColor(calibratedRed: 0x63/255, green: 0x66/255, blue: 0xf1/255, alpha: 1),
    ])
    let path = claudeCodeMarkPath(originX: 0, originY: 0, height: height)
    gradient?.draw(in: path, angle: -45)
    image.unlockFocus()
    return image
}

// Flat black silhouette for the menu bar (template rendering).
func templateMark(height: CGFloat) -> NSImage {
    let width = height * markAspect
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.black.setFill()
    claudeCodeMarkPath(originX: 0, originY: 0, height: height).fill()
    image.unlockFocus()
    return image
}

// Rounded-square badge, piper-style gradient (cyan -> indigo) on dark navy bg,
// Claude Code mark centered with a "%" tucked below it.
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

    // Claude Code mark, centered in the upper-middle of the badge
    let markHeight = size * 0.30
    let mark = gradientMark(height: markHeight)
    mark.draw(at: CGPoint(x: size / 2 - mark.size.width / 2, y: size * 0.5),
              from: .zero, operation: .sourceOver, fraction: 1)

    // "%", centered below the mark
    let pctSize = size * 0.20
    let pctFont = NSFont.monospacedSystemFont(ofSize: pctSize, weight: .bold)
    let pctAttrs: [NSAttributedString.Key: Any] = [
        .font: pctFont,
        .foregroundColor: NSColor(calibratedRed: 0xe2/255, green: 0xe8/255, blue: 0xf0/255, alpha: 1),
    ]
    let pctString = NSAttributedString(string: "%", attributes: pctAttrs)
    let pctBounds = pctString.size()
    pctString.draw(at: CGPoint(x: size / 2 - pctBounds.width / 2, y: size * 0.22))

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
savePNG(templateMark(height: 64), to: "\(outDir)/menubar-mark.png")
print("icons written to \(outDir)")
