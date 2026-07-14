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

    // Eyes widened from the original mark's 1.488-unit cutouts - too thin to
    // read as two dots once scaled down to menu bar size.
    path.move(to: pt(5.6, 10.949))
    for p in [(8.0, 10.949), (8.0, 7.7), (5.6, 7.7), (5.6, 10.949)] {
        path.line(to: pt(CGFloat(p.0), CGFloat(p.1)))
    }
    path.close()

    path.move(to: pt(16.0, 10.949))
    for p in [(18.4, 10.949), (18.4, 7.7), (16.0, 7.7), (16.0, 10.949)] {
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

// Pixel-grid mascot poses (24x24 cell grid, from the Claude mascot SVGs) -
// only cell presence matters for a template silhouette, not their original
// colors, so this ignores fill and just plots filled 24x24 squares.
// Cropped to the cells' own bounding box (not a fixed nominal canvas) so
// every pose fills its frame the same way once scaled into a shared menu
// bar icon box - a fixed canvas left some poses with dead margin (e.g. the
// alert mascot's raised arm leaves empty space elsewhere), making them look
// visually smaller than a pose that fills its canvas edge to edge.
// `eyeHoles` are punched as transparent cutouts independent of the 24-unit
// cell grid (x, y, width, height, all in the same coordinate space as
// `cells`) - lets an eye be a thin closed-eye slit instead of a full square.
func pixelGridMark(cells: [(CGFloat, CGFloat)], height: CGFloat, eyeHoles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []) -> NSImage {
    let minX = cells.map(\.0).min()!
    let maxX = cells.map(\.0).max()! + 24
    let minY = cells.map(\.1).min()!
    let maxY = cells.map(\.1).max()! + 24
    let contentWidth = maxX - minX
    let contentHeight = maxY - minY

    let scale = height / contentHeight
    let width = contentWidth * scale
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.black.setFill()
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    for (x, y) in cells {
        // flip y: SVG is top-left origin, Cocoa drawing here is bottom-left
        let rect = NSRect(x: (x - minX) * scale, y: (maxY - y - 24) * scale, width: 24 * scale, height: 24 * scale)
        path.appendRect(rect)
    }
    for (x, y, w, h) in eyeHoles {
        let rect = NSRect(x: (x - minX) * scale, y: (maxY - y - h) * scale, width: w * scale, height: h * scale)
        path.appendRect(rect)
    }
    path.fill()
    image.unlockFocus()
    return image
}

let alertMascotCells: [(CGFloat, CGFloat)] = [
    (216, 0), (240, 0),
    (216, 24), (240, 24),
    (48, 48), (72, 48), (96, 48), (120, 48), (144, 48), (168, 48), (192, 48), (216, 48), (240, 48),
    (48, 72), (72, 72), (96, 72), (120, 72), (144, 72), (168, 72), (192, 72), (216, 72), (240, 72),
    // (96, 96) and (192, 96) are the eyes in the original mascot (dark pixels
    // against the tan body) - excluded so they render as transparent holes.
    (48, 96), (72, 96), (120, 96), (144, 96), (168, 96), (216, 96), (240, 96),
    // Eyes extended down into this row too (taller, more visible at menu bar size).
    (48, 120), (72, 120), (120, 120), (144, 120), (168, 120), (216, 120), (240, 120),
    (48, 144), (72, 144), (96, 144), (120, 144), (144, 144), (168, 144), (192, 144), (216, 144), (240, 144),
    (48, 168), (72, 168), (96, 168), (120, 168), (144, 168), (168, 168), (192, 168), (216, 168), (240, 168),
    (0, 192), (24, 192), (48, 192), (72, 192), (96, 192), (120, 192), (144, 192), (168, 192), (192, 192), (216, 192), (240, 192),
    (0, 216), (24, 216), (48, 216), (72, 216), (96, 216), (120, 216), (144, 216), (168, 216), (192, 216), (216, 216), (240, 216),
    (48, 240), (120, 240), (168, 240), (240, 240),
    (72, 264), (120, 264), (192, 264), (264, 264),
    (72, 288), (120, 288), (192, 288), (288, 288),
]

let hundredMascotCells: [(CGFloat, CGFloat)] = [
    (48, 0), (72, 0), (96, 0), (120, 0), (144, 0), (168, 0), (192, 0), (216, 0), (240, 0),
    (48, 24), (72, 24), (96, 24), (120, 24), (144, 24), (168, 24), (192, 24), (216, 24), (240, 24),
    (48, 48), (72, 48), (96, 48), (120, 48), (144, 48), (168, 48), (192, 48), (216, 48), (240, 48),
    (48, 72), (72, 72), (96, 72), (120, 72), (144, 72), (168, 72), (192, 72), (216, 72), (240, 72),
    (48, 96), (72, 96), (96, 96), (120, 96), (144, 96), (168, 96), (192, 96), (216, 96), (240, 96),
    (0, 120), (24, 120), (48, 120), (72, 120), (96, 120), (120, 120), (144, 120), (168, 120), (192, 120), (216, 120), (240, 120), (264, 120), (288, 120),
    (0, 144), (24, 144), (48, 144), (72, 144), (96, 144), (120, 144), (144, 144), (168, 144), (192, 144), (216, 144), (240, 144), (264, 144), (288, 144),
    (48, 168), (72, 168), (96, 168), (120, 168), (144, 168), (168, 168), (192, 168), (216, 168), (240, 168),
    (48, 192), (96, 192), (192, 192), (240, 192),
    (48, 216), (96, 216), (192, 216), (240, 216),
    (48, 240), (96, 240), (192, 240), (240, 240),
]

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
savePNG(pixelGridMark(cells: alertMascotCells, height: 64), to: "\(outDir)/menubar-mark-alert.png")
// Closed/sleeping eyes for the 100% pose - thin horizontal slits instead of
// open squares, reads as "exhausted" rather than just "arms up".
// Simple pixel-art X punched through the middle of the body - reads as
// "full" much more clearly than trying to make closed/sleeping eyes work
// at this size.
savePNG(pixelGridMark(cells: hundredMascotCells, height: 64, eyeHoles: [
    (111, 45, 18, 18), (129, 63, 18, 18), (147, 81, 18, 18), (165, 99, 18, 18), (183, 117, 18, 18),
    (201, 45, 18, 18), (183, 63, 18, 18), (165, 81, 18, 18), (147, 99, 18, 18), (129, 117, 18, 18),
]), to: "\(outDir)/menubar-mark-100.png")
print("icons written to \(outDir)")
