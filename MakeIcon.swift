import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let bg = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
    NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.58, alpha: 1).setFill(); bg.fill()
    NSColor.white.withAlphaComponent(0.95).setStroke()
    let globe = NSBezierPath(ovalIn: NSRect(x: 238, y: 258, width: 548, height: 548))
    globe.lineWidth = 27; globe.stroke()
    let equator = NSBezierPath(); equator.move(to: NSPoint(x: 241, y: 532)); equator.line(to: NSPoint(x: 783, y: 532)); equator.lineWidth = 25; equator.stroke()
    let meridian = NSBezierPath(ovalIn: NSRect(x: 379, y: 258, width: 266, height: 548))
    meridian.lineWidth = 25; meridian.stroke()
    let arrowBackground = NSBezierPath(roundedRect: NSRect(x: 502, y: 144, width: 354, height: 305), xRadius: 87, yRadius: 87)
    NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.58, alpha: 1).setFill(); arrowBackground.fill()
    let ring = NSBezierPath()
    ring.appendArc(withCenter: NSPoint(x: 668, y: 301), radius: 101, startAngle: 38, endAngle: 335, clockwise: false)
    ring.lineWidth = 32; ring.lineCapStyle = .round; NSColor.white.setStroke(); ring.stroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 758, y: 359)); arrow.line(to: NSPoint(x: 759, y: 416)); arrow.line(to: NSPoint(x: 702, y: 406))
    arrow.lineWidth = 31; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("icon render") }
    try png.write(to: URL(fileURLWithPath: destination + "/\(size).png"))
}
