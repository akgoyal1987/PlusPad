import AppKit

// Generates PlusPad.iconset. Kept as source rather than checked-in PNGs so the
// icon is reviewable in a diff and regenerates on every build.
//
// Usage: swift make-icon.swift <output.iconset>

/// A sheet of paper with ruled text lines and an orange plus badge. The orange
/// is the same accent the active tab uses, so the icon and the window agree.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let scale = size / 1024
    func s(_ value: CGFloat) -> CGFloat { value * scale }

    NSGraphicsContext.current?.imageInterpolation = .high

    // Rounded slate backing, so the paper reads at 16 points where a plain white
    // sheet on a white desktop would disappear.
    let plate = NSRect(x: s(64), y: s(64), width: s(896), height: s(896))
    let plateShape = NSBezierPath(roundedRect: plate, xRadius: s(200), yRadius: s(200))
    let backing = NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.28, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.16, blue: 0.21, alpha: 1),
    ])
    backing?.draw(in: plateShape, angle: -90)

    // The page, inset and turned very slightly so it reads as a sheet rather
    // than a panel.
    let page = NSRect(x: s(232), y: s(180), width: s(520), height: s(640))
    let transform = NSAffineTransform()
    transform.translateX(by: size / 2, yBy: size / 2)
    transform.rotate(byDegrees: -4)
    transform.translateX(by: -size / 2, yBy: -size / 2)
    NSGraphicsContext.saveGraphicsState()
    transform.concat()

    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28).setFill()
    NSBezierPath(roundedRect: page.offsetBy(dx: s(10), dy: s(-14)),
                 xRadius: s(24), yRadius: s(24)).fill()

    NSColor(srgbRed: 0.99, green: 0.99, blue: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: page, xRadius: s(24), yRadius: s(24)).fill()

    // Ruled lines in the syntax colours: blue keyword, green comment, grey
    // string, orange number -- the palette the editor itself uses.
    let inkColors: [NSColor] = [
        NSColor(srgbRed: 0.0, green: 0.0, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        NSColor(srgbRed: 0.0, green: 0.5, blue: 0.0, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.5, blue: 0.0, alpha: 1),
        NSColor(srgbRed: 0.0, green: 0.0, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
    ]
    // Varied widths and indents so it reads as code, not as a form.
    let widths: [CGFloat] = [300, 380, 250, 340, 200, 300]
    let indents: [CGFloat] = [0, 60, 60, 120, 60, 0]

    var lineY = page.maxY - s(96)
    for (index, color) in inkColors.enumerated() {
        color.setFill()
        let bar = NSRect(x: page.minX + s(62) + s(indents[index]), y: lineY,
                         width: s(widths[index]), height: s(30))
        NSBezierPath(roundedRect: bar, xRadius: s(15), yRadius: s(15)).fill()
        lineY -= s(88)
    }
    NSGraphicsContext.restoreGraphicsState()

    // The plus badge, bottom-right, overlapping the page edge.
    let badgeCentre = NSPoint(x: s(760), y: s(268))
    let badgeRadius = s(150)
    let badge = NSRect(x: badgeCentre.x - badgeRadius, y: badgeCentre.y - badgeRadius,
                       width: badgeRadius * 2, height: badgeRadius * 2)
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3).setFill()
    NSBezierPath(ovalIn: badge.offsetBy(dx: s(6), dy: s(-10))).fill()
    let badgeGradient = NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.66, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.94, green: 0.44, blue: 0.05, alpha: 1),
    ])
    badgeGradient?.draw(in: NSBezierPath(ovalIn: badge), angle: -90)

    NSColor.white.setFill()
    let armLength = s(150), armThickness = s(42)
    NSBezierPath(roundedRect: NSRect(x: badgeCentre.x - armLength / 2,
                                     y: badgeCentre.y - armThickness / 2,
                                     width: armLength, height: armThickness),
                 xRadius: s(12), yRadius: s(12)).fill()
    NSBezierPath(roundedRect: NSRect(x: badgeCentre.x - armThickness / 2,
                                     y: badgeCentre.y - armLength / 2,
                                     width: armThickness, height: armLength),
                 xRadius: s(12), yRadius: s(12)).fill()
    return image
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The names iconutil expects.
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in variants {
    let image = drawIcon(size: pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: output.appendingPathComponent(name))
}
print("wrote \(variants.count) images to \(output.path)")
