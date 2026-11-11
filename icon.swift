// Draws the Kaypoh app icon (1024 px PNG): a big emoji bell on a sunset-to-lagoon gradient,
// with a few of the notice badges' emoji orbiting it. Full-bleed square: macOS applies its own
// rounded mask. Usage: swift icon.swift OUT.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let canvas = CGRect(x: 0, y: 0, width: size, height: size)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: a) }

// Coral (top-left) through violet to lagoon teal (bottom-right).
NSGradient(colors: [rgb(1.00, 0.55, 0.42), rgb(0.62, 0.38, 0.95), rgb(0.18, 0.72, 0.78)])!.draw(in: canvas, angle: -50)
// Soft glow behind the bell.
NSGradient(colors: [NSColor(white: 1, alpha: 0.45), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSBezierPath(ovalIn: canvas.insetBy(dx: 150, dy: 150)), relativeCenterPosition: .zero)

func emoji(_ s: String, _ pt: CGFloat, center: CGPoint, angle: CGFloat = 0, shadow: CGFloat = 24) {
    let text = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: pt)])
    let b = text.boundingRect(with: NSSize(width: size, height: size), options: [.usesLineFragmentOrigin])
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -shadow / 2), blur: shadow, color: NSColor(white: 0, alpha: 0.28).cgColor)
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    text.draw(at: CGPoint(x: -b.width / 2, y: -b.height / 2))
    ctx.restoreGState()
}

// The bell, tilted mid-ring.
emoji("🔔", 520, center: CGPoint(x: 500, y: 490), angle: 12, shadow: 40)
// Orbiting callers: who might be ringing.
emoji("👋", 150, center: CGPoint(x: 205, y: 790), angle: -14)
emoji("🎉", 150, center: CGPoint(x: 830, y: 800), angle: 10)
emoji("🔐", 130, center: CGPoint(x: 845, y: 235), angle: 8)
emoji("🚀", 130, center: CGPoint(x: 190, y: 225), angle: -20)
emoji("✨", 110, center: CGPoint(x: 800, y: 520), angle: 0, shadow: 10)

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
