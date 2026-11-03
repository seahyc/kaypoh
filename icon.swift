// Draws the Agent Notify icon (1024 px PNG): a soft indigo-to-teal squircle with a white bell
// and a small amber spark. Usage: swift icon.swift OUT.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: the badge fills ~80% of the canvas with a continuous-corner squircle.
let inset: CGFloat = 100
let badge = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: badge, xRadius: 185, yRadius: 185)

// Soft shadow under the badge.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor(white: 0, alpha: 0.28).cgColor)
NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.62, alpha: 1).setFill()
squircle.fill()
ctx.restoreGState()

// Indigo (top-left) to teal (bottom-right).
squircle.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.29, green: 0.31, blue: 0.75, alpha: 1),
    NSColor(calibratedRed: 0.23, green: 0.47, blue: 0.80, alpha: 1),
    NSColor(calibratedRed: 0.17, green: 0.66, blue: 0.68, alpha: 1),
])!
gradient.draw(in: badge, angle: -50)

// Gentle top sheen.
let sheen = NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])!
sheen.draw(in: CGRect(x: badge.minX, y: badge.midY, width: badge.width, height: badge.height / 2), angle: -90)

// Bell.
let cx = size / 2
let bell = NSBezierPath()
let top: CGFloat = 712, rim: CGFloat = 372, half: CGFloat = 196
bell.move(to: CGPoint(x: cx - half, y: rim))
bell.curve(to: CGPoint(x: cx - 150, y: 560), controlPoint1: CGPoint(x: cx - 150, y: rim + 40), controlPoint2: CGPoint(x: cx - 160, y: 470))
bell.curve(to: CGPoint(x: cx, y: top), controlPoint1: CGPoint(x: cx - 140, y: 660), controlPoint2: CGPoint(x: cx - 80, y: top))
bell.curve(to: CGPoint(x: cx + 150, y: 560), controlPoint1: CGPoint(x: cx + 80, y: top), controlPoint2: CGPoint(x: cx + 140, y: 660))
bell.curve(to: CGPoint(x: cx + half, y: rim), controlPoint1: CGPoint(x: cx + 160, y: 470), controlPoint2: CGPoint(x: cx + 150, y: rim + 40))
bell.close()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor(white: 0, alpha: 0.18).cgColor)
NSColor.white.setFill()
bell.fill()
// Rim, clapper and hanger.
NSBezierPath(roundedRect: CGRect(x: cx - 230, y: rim - 34, width: 460, height: 58), xRadius: 29, yRadius: 29).fill()
NSBezierPath(ovalIn: CGRect(x: cx - 48, y: rim - 128, width: 96, height: 96)).fill()
NSBezierPath(ovalIn: CGRect(x: cx - 30, y: top - 22, width: 60, height: 60)).fill()
ctx.restoreGState()

// Amber spark, top right: four-pointed star.
func spark(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let k = r * 0.22
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + k, y: c.y + k), controlPoint2: CGPoint(x: c.x + k, y: c.y + k))
    p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + k, y: c.y - k), controlPoint2: CGPoint(x: c.x + k, y: c.y - k))
    p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - k, y: c.y - k), controlPoint2: CGPoint(x: c.x - k, y: c.y - k))
    p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - k, y: c.y + k), controlPoint2: CGPoint(x: c.x - k, y: c.y + k))
    p.close()
    return p
}
NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.36, alpha: 1).setFill()
spark(CGPoint(x: cx + 228, y: 690), 92).fill()
NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.55, alpha: 0.9).setFill()
spark(CGPoint(x: cx + 320, y: 588), 38).fill()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
