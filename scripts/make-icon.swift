// Draws the app icon (1024 px) as a PNG: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGradient(colors: [
    NSColor(red: 0.06, green: 0.08, blue: 0.16, alpha: 1),
    NSColor(red: 0.14, green: 0.10, blue: 0.30, alpha: 1),
])!.draw(in: shape, angle: -90)

// Bars like a history chart
let bars: [CGFloat] = [0.25, 0.4, 0.3, 0.55, 0.45, 0.7, 0.5, 0.35]
let barWidth: CGFloat = 58, gap: CGFloat = 16
let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
let base: CGFloat = 250
for (i, h) in bars.enumerated() {
    let x = (size - totalWidth) / 2 + CGFloat(i) * (barWidth + gap)
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: base, width: barWidth, height: 420 * h), xRadius: 14, yRadius: 14)
    NSGradient(colors: [
        NSColor(red: 0.30, green: 0.75, blue: 1.00, alpha: 0.30),
        NSColor(red: 0.75, green: 0.45, blue: 1.00, alpha: 0.30),
    ])!.draw(in: bar, angle: 90)
}

// Pulse line with a glow
let line = NSBezierPath()
let points: [(CGFloat, CGFloat)] = [(180, 500), (380, 500), (440, 380), (520, 720), (590, 300), (650, 560), (700, 500), (844, 500)]
line.move(to: NSPoint(x: points[0].0, y: points[0].1))
for p in points.dropFirst() { line.line(to: NSPoint(x: p.0, y: p.1)) }
line.lineWidth = 44
line.lineCapStyle = .round
line.lineJoinStyle = .round

NSGraphicsContext.current?.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = NSColor(red: 0.3, green: 0.9, blue: 0.7, alpha: 0.9)
glow.shadowBlurRadius = 40
glow.set()
NSColor(red: 0.30, green: 0.95, blue: 0.70, alpha: 1).setStroke()
line.stroke()
NSGraphicsContext.current?.restoreGraphicsState()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
