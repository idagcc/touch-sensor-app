import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = root.appendingPathComponent(".build/artwork")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let mint = NSColor(srgbRed: 0.65, green: 0.94, blue: 0.77, alpha: 1)
let ink = NSColor(srgbRed: 0.035, green: 0.055, blue: 0.065, alpha: 1)

func render(width: Int, height: Int, draw: () -> Void) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

func text(_ value: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let str = NSString(string: value)
    let size = str.size(withAttributes: attributes)
    str.draw(at: NSPoint(x: (1280-size.width)/2, y: y), withAttributes: attributes)
}

for holding in [true, false] {
    let data = render(width: 1280, height: 720) {
        ink.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1280, height: 720)).fill()
        for (index, diameter) in [CGFloat(400), 310, 220].enumerated() {
            mint.withAlphaComponent(CGFloat(index+1)*0.025).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 640-diameter/2, y: 470-diameter/2, width: diameter, height: diameter))
            ring.lineWidth = 1.5; ring.stroke()
        }
        mint.setFill()
        NSBezierPath(ovalIn: NSRect(x: 608, y: 438, width: 64, height: 64)).fill()
        ink.setFill()
        if holding { NSBezierPath(ovalIn: NSRect(x: 632, y: 462, width: 16, height: 16)).fill() }
        else {
            let path = NSBezierPath(); path.move(to: NSPoint(x: 633, y: 452)); path.line(to: NSPoint(x: 633, y: 488)); path.line(to: NSPoint(x: 658, y: 470)); path.close(); path.fill()
        }
        text("TOUCH PLAYER", size: 14, weight: .bold, color: mint, y: 663)
        text(holding ? "Ready for your touch." : "Playback in motion.", size: 46, weight: .medium, color: .white, y: 270)
        text(holding ? "The holding video loops until you press play." : "Pause, resume, or reset with your Arduino buttons.", size: 19, weight: .regular, color: NSColor(white: 0.55, alpha: 1), y: 226)
        text("DEMO VIDEO  ·  REPLACE THIS FILE WITH YOUR OWN", size: 12, weight: .medium, color: NSColor(white: 0.35, alpha: 1), y: 40)
    }
    try data.write(to: assets.appendingPathComponent(holding ? "holding.png" : "playback.png"))
}

let iconset = assets.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base*scale
        let p = CGFloat(pixels)
        let data = render(width: pixels, height: pixels) {
            NSColor.clear.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: p, height: p)).fill()
            ink.setFill(); NSBezierPath(roundedRect: NSRect(x: p*0.045, y: p*0.045, width: p*0.91, height: p*0.91), xRadius: p*0.21, yRadius: p*0.21).fill()
            mint.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: p*0.23, y: p*0.23, width: p*0.54, height: p*0.54))
            ring.lineWidth = p*0.035; ring.stroke()
            mint.setFill()
            let triangle = NSBezierPath(); triangle.move(to: NSPoint(x: p*0.44, y: p*0.35)); triangle.line(to: NSPoint(x: p*0.44, y: p*0.65)); triangle.line(to: NSPoint(x: p*0.66, y: p*0.5)); triangle.close(); triangle.fill()
        }
        try data.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
    }
}
