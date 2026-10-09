import AppKit
let output = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
let path = NSBezierPath(roundedRect: rect, xRadius: 195, yRadius: 195)
NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.20, blue: 0.24, alpha: 1), ending: NSColor(srgbRed: 0.035, green: 0.09, blue: 0.13, alpha: 1))!.draw(in: path, angle: -75)
let amber = NSColor(srgbRed: 1, green: 0.72, blue: 0.30, alpha: 1)
// A rising sun above a terminal prompt. All artwork is native vector drawing.
amber.setStroke()
let sun = NSBezierPath(); sun.lineWidth = 33; sun.lineCapStyle = .round
sun.appendArc(withCenter: NSPoint(x: 512, y: 505), radius: 153, startAngle: 0, endAngle: 180)
sun.stroke()
for angle in stride(from: 0.0, through: 180.0, by: 30) {
    let theta = angle * .pi / 180
    let ray = NSBezierPath(); ray.lineWidth = 28; ray.lineCapStyle = .round
    ray.move(to: NSPoint(x: 512 + cos(theta) * 212, y: 505 + sin(theta) * 212))
    ray.line(to: NSPoint(x: 512 + cos(theta) * 252, y: 505 + sin(theta) * 252)); ray.stroke()
}
let horizon = NSBezierPath(); horizon.lineWidth = 27; horizon.lineCapStyle = .round
horizon.move(to: NSPoint(x: 268, y: 493)); horizon.line(to: NSPoint(x: 756, y: 493)); horizon.stroke()
NSColor(srgbRed: 0.85, green: 0.95, blue: 0.94, alpha: 1).setStroke()
let terminal = NSBezierPath(); terminal.lineWidth = 35; terminal.lineCapStyle = .round; terminal.lineJoinStyle = .round
terminal.move(to: NSPoint(x: 359, y: 397)); terminal.line(to: NSPoint(x: 421, y: 347)); terminal.line(to: NSPoint(x: 359, y: 297)); terminal.stroke()
let cursor = NSBezierPath(); cursor.lineWidth = 32; cursor.lineCapStyle = .round
cursor.move(to: NSPoint(x: 505, y: 298)); cursor.line(to: NSPoint(x: 641, y: 298)); cursor.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
