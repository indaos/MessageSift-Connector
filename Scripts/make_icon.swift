// Draws the MessageSift Connector app icon (same palette and frame as MessageSift, with a plug) at every
// macOS size and writes Sources/App/Assets.xcassets/AppIcon.appiconset.
//   swift Scripts/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("Sources/App/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The icon on a 1024-point canvas, scaled to `pixels`.
func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // Frame: the MessageSift squircle and gradient.
    let frame = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: color(0x5954EC), ending: color(0x9940DF))!.draw(in: frame, angle: -45)

    // A white tile, like MessageSift's speech bubble, without the tail: a helper, not a chat.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 250, y: 300, width: 524, height: 440), xRadius: 110, yRadius: 110).fill()

    // The plug, in MessageSift's orange.
    let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold)
    if let plug = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: plug.size, flipped: false) { r in
            plug.draw(in: r)
            color(0xFF9628).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = plug.size, box = NSRect(x: 250, y: 300, width: 524, height: 440)
        let scale = min(400 / s.width, 320 / s.height)
        let w = s.width * scale, h = s.height * scale
        tinted.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
    }

    // The three source dots of MessageSift, joined: notifications and WhatsApp flowing in.
    NSColor.white.setStroke()
    let line = NSBezierPath(); line.move(to: NSPoint(x: 340, y: 204)); line.line(to: NSPoint(x: 680, y: 204)); line.lineWidth = 7; line.stroke()
    for (x, c) in [(340.0, 0x3385FF), (510.0, 0x30C759), (680.0, 0x9E45D9)] as [(CGFloat, UInt32)] {
        let dot = NSBezierPath(ovalIn: NSRect(x: x - 24, y: 180, width: 48, height: 48))
        color(c).setFill(); dot.fill()
        NSColor.white.setStroke(); dot.lineWidth = 7; dot.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try! render(size * scale).write(to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: set.appendingPathComponent("Contents.json"))
let catalog = set.deletingLastPathComponent().appendingPathComponent("Contents.json")
try! JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted]).write(to: catalog)
print("wrote \(images.count) images to \(set.path)")
