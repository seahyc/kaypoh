// Draws one badge per kind of notice: a big emoji on a bright gradient tile, so a glance tells
// you who is calling and why. Each notice carries its badge as an image on the right.
// Usage: swift badges.swift OUT_DIR   (build.sh puts them in the app's Resources/badges)
import AppKit

let kinds: [(name: String, emoji: String, from: (CGFloat, CGFloat, CGFloat), to: (CGFloat, CGFloat, CGFloat))] = [
    ("claude-waiting",    "👋", (0.98, 0.62, 0.42), (0.85, 0.36, 0.25)),  // Claude coral: your turn
    ("claude-permission", "🙋", (1.00, 0.45, 0.35), (0.80, 0.16, 0.30)),  // hot red: hand raised
    ("codex-done",        "🎉", (0.35, 0.90, 0.70), (0.10, 0.55, 0.60)),  // mint: turn finished
    ("browser-handoff",   "🧩", (0.40, 0.70, 1.00), (0.25, 0.30, 0.85)),  // blue: captcha / step in
    ("browser-signin",    "🚪", (0.55, 0.80, 1.00), (0.20, 0.45, 0.80)),  // sky: sign in
    ("browser-debug",     "🔌", (0.45, 0.85, 0.95), (0.15, 0.50, 0.75)),  // cyan: click Allow
    ("vault-approval",    "🔐", (1.00, 0.85, 0.35), (0.90, 0.50, 0.10)),  // gold: approve access
    ("run-ok",            "🚀", (0.55, 0.92, 0.45), (0.15, 0.62, 0.35)),  // green: landed
    ("run-failed",        "💥", (1.00, 0.40, 0.40), (0.60, 0.10, 0.20)),  // red: faceplant
    ("pile",              "📚", (0.80, 0.60, 1.00), (0.45, 0.25, 0.80)),  // purple: N more
    ("bell",              "🔔", (0.45, 0.50, 0.95), (0.20, 0.65, 0.70)),  // indigo-teal: anything else
]

let size: CGFloat = 512
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "badges"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ c: (CGFloat, CGFloat, CGFloat)) -> NSColor { NSColor(calibratedRed: c.0, green: c.1, blue: c.2, alpha: 1) }

for kind in kinds {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let tile = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), xRadius: 110, yRadius: 110)
    tile.addClip()
    NSGradient(colors: [color(kind.from), color(kind.to)])!.draw(in: tile.bounds, angle: -55)
    // Confetti-ish sheen: a soft light blob top-left.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSBezierPath(ovalIn: CGRect(x: -80, y: size * 0.45, width: size * 0.9, height: size * 0.9)), relativeCenterPosition: .zero)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(white: 0, alpha: 0.30).cgColor)
    let text = NSAttributedString(string: kind.emoji, attributes: [.font: NSFont.systemFont(ofSize: 300)])
    let bounds = text.boundingRect(with: NSSize(width: size, height: size), options: [.usesLineFragmentOrigin])
    text.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2 + 4))
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(kind.name).png"))
}
print("\(kinds.count) badges in \(outDir)")
