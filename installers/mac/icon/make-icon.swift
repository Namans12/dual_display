// Draws the "Extended Display" app icon with CoreGraphics only (no assets, no network).
// Usage: swift make-icon.swift <output-dir>
// Writes <output-dir>/icon-1024.png (full detail) and <output-dir>/icon-small-1024.png, a bolder,
// simplified variant (thicker bezels, no fine detail) that build-icon.sh downsamples for the
// 16/32/64 px sizes so the icon stays readable there.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S = 1024
guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255,
                                         CGFloat((hex >> 8) & 255) / 255,
                                         CGFloat(hex & 255) / 255, a])!
}
func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
}
func rrect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// macOS-style squircle (superellipse) tile.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func render(bold: Bool) -> CGImage {
    guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    // y-down coordinates (0,0 = top-left) keep the layout easy to reason about.
    ctx.translateBy(x: 0, y: CGFloat(S))
    ctx.scaleBy(x: 1, y: -1)

    // Standard macOS tile: 824x824 centred in the 1024 canvas.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(tileRect)

    // 1. Drop shadow under the tile (shadow offsets are in device space, so -y is down).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.38))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0x3A2A9C))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Soft vertical indigo/violet gradient, plus a faint sheen at the top.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient(0x7A63F2, 0x3B2A9E),
                           start: CGPoint(x: 0, y: tileRect.minY), end: CGPoint(x: 0, y: tileRect.maxY), options: [])
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray,
                                      locations: [0, 1])!,
                           start: CGPoint(x: 0, y: tileRect.minY), end: CGPoint(x: 0, y: tileRect.minY + 300), options: [])
    ctx.restoreGState()

    // 3. Devices: monitor on the left, landscape tablet on the right. The group is shifted
    //    down a little so it is optically centred (the monitor stand adds weight at the bottom).
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 32)

    let white = rgb(0xFFFFFF)
    let screenCol = rgb(0x1D1458)
    let monBezel: CGFloat = bold ? 44 : 28
    let tabBezel: CGFloat = bold ? 34 : 21

    let monBody = CGRect(x: 142, y: 270, width: 460, height: 350)
    let monScreen = monBody.insetBy(dx: monBezel, dy: monBezel)
    let tabletBody = CGRect(x: 626, y: 390, width: 256, height: 230)
    let tabScreen = tabletBody.insetBy(dx: tabBezel, dy: tabBezel)

    // Monitor stand (neck + base), drawn first so the body overlaps it.
    ctx.setFillColor(rgb(0xE9E6FF))
    ctx.addPath(rrect(CGRect(x: 332, y: 600, width: 88, height: 70), 8)); ctx.fillPath()
    ctx.setFillColor(white)
    ctx.addPath(rrect(CGRect(x: 236, y: 650, width: 264, height: bold ? 46 : 40), 20)); ctx.fillPath()

    // Bodies and screens.
    ctx.addPath(rrect(monBody, 46)); ctx.fillPath()
    ctx.addPath(rrect(tabletBody, 42)); ctx.fillPath()
    let monScreenPath = rrect(monScreen, bold ? 14 : 22)
    let tabScreenPath = rrect(tabScreen, bold ? 14 : 24)
    ctx.setFillColor(screenCol)
    ctx.addPath(monScreenPath); ctx.fillPath()
    ctx.addPath(tabScreenPath); ctx.fillPath()

    // 4. One continuous "window" spanning both screens. It is clipped to the two screens, so the
    //    gap between the devices visibly interrupts it: the desktop is extended onto the tablet.
    //    It bleeds off the right and bottom of the screens; only its top-left corner is visible.
    ctx.saveGState()
    ctx.addPath(monScreenPath)
    ctx.addPath(tabScreenPath)
    ctx.clip()
    let win = CGRect(x: bold ? 330 : 360, y: bold ? 462 : 450, width: 700, height: 320)
    ctx.addPath(rrect(win, 26))
    ctx.clip()
    ctx.drawLinearGradient(gradient(0xFFC83D, 0xFF8A3D),
                           start: CGPoint(x: 0, y: win.minY), end: CGPoint(x: 0, y: win.maxY), options: [])
    if !bold {
        ctx.setFillColor(rgb(0xFFFFFF, 0.38))   // title bar, continuous across the gap
        ctx.fill(CGRect(x: win.minX, y: win.minY, width: win.width, height: 46))
    }
    ctx.restoreGState()

    // Small teal "desktop items" on the monitor screen (full-detail variant only).
    if !bold {
        ctx.setFillColor(rgb(0x4FD8C4))
        ctx.addPath(rrect(CGRect(x: monScreen.minX + 30, y: monScreen.minY + 30, width: 130, height: 30), 15))
        ctx.fillPath()
        ctx.setFillColor(rgb(0x4FD8C4, 0.55))
        ctx.addPath(rrect(CGRect(x: monScreen.minX + 30, y: monScreen.minY + 80, width: 84, height: 30), 15))
        ctx.fillPath()
    } else {
        ctx.setFillColor(rgb(0x4FD8C4))
        ctx.addPath(rrect(CGRect(x: monScreen.minX + 26, y: monScreen.minY + 26, width: 120, height: 44), 22))
        ctx.fillPath()
    }
    ctx.restoreGState()

    guard let img = ctx.makeImage() else { fatalError("no image") }
    return img
}

func writePNG(_ img: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create PNG destination")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write PNG") }
    print("wrote \(url.path)")
}

writePNG(render(bold: false), "icon-1024.png")
writePNG(render(bold: true), "icon-small-1024.png")
