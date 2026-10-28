import AppKit

// Renders the app icon at 1024x1024: a blue squircle, a white folder, and a yellow bolt.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

let inset: CGFloat = size * 0.1
let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let plateRadius = plate.width * 0.225
let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.95, alpha: 1).setFill()
platePath.fill()
ctx.restoreGState()

platePath.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.0, alpha: 1),
                    NSColor(calibratedRed: 0.13, green: 0.30, blue: 0.85, alpha: 1)])!
    .draw(in: plate, angle: -90)

func folder(back: Bool) -> NSBezierPath {
    let w = plate.width * 0.62, h = plate.height * 0.44
    let x = plate.midX - w / 2, y = plate.midY - h / 2 - plate.height * 0.02
    let r = w * 0.06
    let p = NSBezierPath()
    if back {
        let tabW = w * 0.38, tabH = h * 0.16
        p.move(to: NSPoint(x: x, y: y + r))
        p.appendArc(withCenter: NSPoint(x: x + r, y: y + r), radius: r, startAngle: 180, endAngle: 270)
        p.line(to: NSPoint(x: x + w - r, y: y))
        p.appendArc(withCenter: NSPoint(x: x + w - r, y: y + r), radius: r, startAngle: 270, endAngle: 360)
        p.line(to: NSPoint(x: x + w, y: y + h - r))
        p.appendArc(withCenter: NSPoint(x: x + w - r, y: y + h - r), radius: r, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: x + tabW + tabH, y: y + h))
        p.line(to: NSPoint(x: x + tabW, y: y + h + tabH))
        p.line(to: NSPoint(x: x + r, y: y + h + tabH))
        p.appendArc(withCenter: NSPoint(x: x + r, y: y + h + tabH - r), radius: r, startAngle: 90, endAngle: 180)
        p.close()
    } else {
        let front = NSRect(x: x, y: y, width: w, height: h * 0.72)
        p.appendRoundedRect(front, xRadius: r, yRadius: r)
    }
    return p
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.025, color: NSColor.black.withAlphaComponent(0.25).cgColor)
NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
folder(back: true).fill()
ctx.restoreGState()
NSColor.white.setFill()
folder(back: false).fill()

let bolt = NSBezierPath()
let bx = plate.midX + plate.width * 0.17, by = plate.midY - plate.height * 0.22, s = plate.width * 0.22
let pts: [(CGFloat, CGFloat)] = [(0.55, 1.0), (0.05, 0.42), (0.42, 0.42), (0.30, 0.0), (0.85, 0.58), (0.48, 0.58)]
for (i, (px, py)) in pts.enumerated() {
    let pt = NSPoint(x: bx + px * s - s / 2, y: by + py * s - s / 2)
    if i == 0 { bolt.move(to: pt) } else { bolt.line(to: pt) }
}
bolt.close()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.02, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.20, alpha: 1).setFill()
bolt.fill()
ctx.restoreGState()

image.unlockFocus()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
