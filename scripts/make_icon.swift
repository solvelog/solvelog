import Cocoa

// Renders the 1024x1024 app icon for SolveLog: a deep indigo tile with five rounded
// squares climbing diagonally, fading in as they go, the last one an accepted (green)
// submission with a check mark. Reads as "a record of solves, trending upwards".
let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824pt content area with a 100pt margin
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

// soft drop shadow so the tile sits on the Dock like a native app
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = hex(0x060B1C, 0.35)
shadow.shadowBlurRadius = 32
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
hex(0x14204A).setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: hex(0x2A4A93), ending: hex(0x070C22))!.draw(in: squircle, angle: -90)

// five tiles climbing to the right, each brighter than the last
let n = 5
let tile: CGFloat = 116, step: CGFloat = 122
let x0: CGFloat = 198, y0: CGFloat = 198
let lastRect = NSRect(x: x0 + CGFloat(n - 1) * step, y: y0 + CGFloat(n - 1) * step, width: tile, height: tile)

for i in 0..<n {
    let rect = NSRect(x: x0 + CGFloat(i) * step, y: y0 + CGFloat(i) * step, width: tile, height: tile)
    let path = NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32)
    if i == n - 1 {
        NSGradient(starting: hex(0x4EE6AF), ending: hex(0x0FA173))!.draw(in: path, angle: -90)
    } else {
        hex(0xFFFFFF, 0.24 + 0.18 * CGFloat(i)).setFill()
        path.fill()
    }
}

// check mark inside the last tile
let check = NSBezierPath()
check.lineWidth = 15
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: NSPoint(x: lastRect.minX + 0.27 * tile, y: lastRect.minY + 0.52 * tile))
check.line(to: NSPoint(x: lastRect.minX + 0.44 * tile, y: lastRect.minY + 0.35 * tile))
check.line(to: NSPoint(x: lastRect.minX + 0.75 * tile, y: lastRect.minY + 0.67 * tile))
NSColor.white.setStroke()
check.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
