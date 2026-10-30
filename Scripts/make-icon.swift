// Renders Kumquat's original app icon (a kumquat with two leaves on a green squircle)
// at 1024×1024. Usage: swift Scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let side = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// Background squircle on Apple's 1024 grid (824 body, 100 margin).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x1D4A30))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x3C7A50), rgb(0x1E5233), rgb(0x123522)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.drawRadialGradient(gradient([rgb(0xFFD27A, 0.28), rgb(0xFFD27A, 0)], [0, 1]),
                       startCenter: CGPoint(x: 520, y: 500), startRadius: 0,
                       endCenter: CGPoint(x: 520, y: 500), endRadius: 420, options: [])

// Fruit.
let center = CGPoint(x: 500, y: 455)
let tilt: CGFloat = -0.36
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: tilt)
let fruitRect = CGRect(x: -210, y: -262, width: 420, height: 524)
let fruit = CGPath(ellipseIn: fruitRect, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 10, height: -26), blur: 46, color: rgb(0x000000, 0.42))
ctx.addPath(fruit)
ctx.setFillColor(rgb(0xF07A10))
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(fruit)
ctx.clip()
ctx.drawRadialGradient(gradient([rgb(0xFFD58A), rgb(0xFFA62B), rgb(0xF07A10), rgb(0xC65005)], [0, 0.32, 0.72, 1]),
                       startCenter: CGPoint(x: -80, y: 120), startRadius: 10,
                       endCenter: CGPoint(x: 0, y: 0), endRadius: 300, options: [.drawsAfterEndLocation])
// Peel pores, deterministic.
var seed: UInt64 = 0x4B4D5154
func random() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(1 << 31)
}
for _ in 0..<170 {
    let x = (random() * 2 - 1) * 200, y = (random() * 2 - 1) * 250
    guard (x * x) / (200 * 200) + (y * y) / (252 * 252) < 0.92 else { continue }
    let r = 2.5 + random() * 4.5
    ctx.setFillColor(rgb(0xB84A04, 0.16 + random() * 0.14))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 1.6))
}
// Specular highlight.
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.6), rgb(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: -95, y: 130), startRadius: 0,
                       endCenter: CGPoint(x: -95, y: 130), endRadius: 95, options: [])
// Rim light along the lower right edge.
ctx.setStrokeColor(rgb(0xFFC060, 0.35))
ctx.setLineWidth(10)
ctx.addEllipse(in: fruitRect.insetBy(dx: 6, dy: 6).offsetBy(dx: 8, dy: -8))
ctx.strokePath()
ctx.restoreGState()

// Top of the fruit in canvas coordinates.
let top = CGPoint(x: center.x - 262 * sin(tilt), y: center.y + 262 * cos(tilt))

func leafPath(base: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: .zero)
    path.addCurve(to: CGPoint(x: length, y: 0), control1: CGPoint(x: length * 0.25, y: width), control2: CGPoint(x: length * 0.75, y: width * 0.85))
    path.addCurve(to: .zero, control1: CGPoint(x: length * 0.75, y: -width * 0.85), control2: CGPoint(x: length * 0.25, y: -width))
    var transform = CGAffineTransform(translationX: base.x, y: base.y).rotated(by: angle)
    return path.copy(using: &transform)!
}

func drawLeaf(base: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat, light: UInt32, dark: UInt32) {
    let path = leafPath(base: base, angle: angle, length: length, width: width)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 4, height: -10), blur: 18, color: rgb(0x000000, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(rgb(dark))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let tip = CGPoint(x: base.x + cos(angle) * length, y: base.y + sin(angle) * length)
    ctx.drawLinearGradient(gradient([rgb(light), rgb(dark)], [0, 1]),
                           start: CGPoint(x: base.x - sin(angle) * width, y: base.y + cos(angle) * width),
                           end: CGPoint(x: tip.x + sin(angle) * width, y: tip.y - cos(angle) * width), options: [])
    ctx.setStrokeColor(rgb(0x1F5A2A, 0.55))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.move(to: base)
    ctx.addQuadCurve(to: CGPoint(x: base.x + cos(angle) * length * 0.9, y: base.y + sin(angle) * length * 0.9),
                     control: CGPoint(x: base.x + cos(angle + 0.06) * length * 0.5, y: base.y + sin(angle + 0.06) * length * 0.5))
    ctx.strokePath()
    ctx.restoreGState()
}

let stemBase = CGPoint(x: top.x - 4, y: top.y - 14)
drawLeaf(base: stemBase, angle: 2.35, length: 175, width: 50, light: 0x7CC46F, dark: 0x2F7A3A)
drawLeaf(base: stemBase, angle: 0.52, length: 265, width: 74, light: 0x9EDB86, dark: 0x3A8F45)
// Stem.
ctx.setFillColor(rgb(0x6B4A22))
ctx.addPath(CGPath(roundedRect: CGRect(x: stemBase.x - 13, y: stemBase.y - 6, width: 26, height: 36), cornerWidth: 10, cornerHeight: 10, transform: nil))
ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path)")
