// Renders the app icon to a 1024x1024 PNG: swift tools/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// macOS icon grid: 824pt body centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0.1, 0.1, 0.2)); ctx.fillPath()
ctx.restoreGState()

// Background gradient: deep stage-light magenta to indigo
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0.98, 0.27, 0.42), color(0.55, 0.18, 0.78), color(0.16, 0.14, 0.52)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 940), end: CGPoint(x: 860, y: 90), options: [])
// soft top highlight
let hl = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.28), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 360, y: 900), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 900), endRadius: 620, options: [])
ctx.restoreGState()

// Two SD cards: a ghost "copy" behind, the real card in front.
func sdCardPath(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let notch = r.width * 0.26
    let rad: CGFloat = 34
    p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + rad), control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - notch))
    p.addLine(to: CGPoint(x: r.maxX - notch, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
    p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    p.closeSubpath()
    return p
}

let cardW: CGFloat = 400, cardH: CGFloat = 520
let back = CGRect(x: 352, y: 290, width: cardW, height: cardH)
let front = CGRect(x: 272, y: 214, width: cardW, height: cardH)

// back card: translucent white outline (the copy)
ctx.saveGState()
ctx.addPath(sdCardPath(back))
ctx.setFillColor(color(1, 1, 1, 0.16)); ctx.fillPath()
ctx.addPath(sdCardPath(back))
ctx.setStrokeColor(color(1, 1, 1, 0.55)); ctx.setLineWidth(10); ctx.strokePath()
ctx.restoreGState()

// front card: solid near-black with shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0, 0, 0, 0.45))
ctx.addPath(sdCardPath(front))
let cardGrad = CGGradient(colorsSpace: cs, colors: [color(0.22, 0.22, 0.26), color(0.09, 0.09, 0.11)] as CFArray, locations: [0, 1])!
ctx.setFillColor(color(0.12, 0.12, 0.14)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(sdCardPath(front)); ctx.clip()
ctx.drawLinearGradient(cardGrad, start: CGPoint(x: front.minX, y: front.maxY), end: CGPoint(x: front.maxX, y: front.minY), options: [])
ctx.restoreGState()

// gold contacts along the top of the front card
let contactW: CGFloat = 34, contactH: CGFloat = 82, gap: CGFloat = 14
let contactsTop = front.maxY - 34
var x = front.minX + 40
let gold = CGGradient(colorsSpace: cs, colors: [color(1.0, 0.86, 0.48), color(0.85, 0.62, 0.22)] as CFArray, locations: [0, 1])!
for _ in 0..<6 {
    let r = CGRect(x: x, y: contactsTop - contactH, width: contactW, height: contactH)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(gold, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.restoreGState()
    x += contactW + gap
}

// label stripe on the card
ctx.addPath(CGPath(roundedRect: CGRect(x: front.minX + 40, y: front.minY + 60, width: cardW - 80, height: 150),
                   cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.setFillColor(color(1, 1, 1, 0.08)); ctx.fillPath()

// green verified badge with checkmark, bottom-right
let badgeC = CGPoint(x: 700, y: 300), badgeR: CGFloat = 150
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.4))
ctx.addEllipse(in: CGRect(x: badgeC.x - badgeR, y: badgeC.y - badgeR, width: badgeR * 2, height: badgeR * 2))
ctx.setFillColor(color(0.2, 0.8, 0.4)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: badgeC.x - badgeR, y: badgeC.y - badgeR, width: badgeR * 2, height: badgeR * 2)); ctx.clip()
let green = CGGradient(colorsSpace: cs, colors: [color(0.42, 0.93, 0.52), color(0.13, 0.68, 0.33)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(green, start: CGPoint(x: badgeC.x, y: badgeC.y + badgeR), end: CGPoint(x: badgeC.x, y: badgeC.y - badgeR), options: [])
ctx.restoreGState()
ctx.addEllipse(in: CGRect(x: badgeC.x - badgeR, y: badgeC.y - badgeR, width: badgeR * 2, height: badgeR * 2))
ctx.setStrokeColor(color(1, 1, 1, 0.9)); ctx.setLineWidth(12); ctx.strokePath()

let check = CGMutablePath()
check.move(to: CGPoint(x: badgeC.x - 68, y: badgeC.y + 2))
check.addLine(to: CGPoint(x: badgeC.x - 18, y: badgeC.y - 50))
check.addLine(to: CGPoint(x: badgeC.x + 72, y: badgeC.y + 58))
ctx.addPath(check)
ctx.setStrokeColor(color(1, 1, 1)); ctx.setLineWidth(36); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
