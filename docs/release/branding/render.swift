import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Adapt the pinned Lucide shield-check paths to CoreGraphics. SVG corner arcs
// are approximated with quadratic curves; the original SVG remains alongside.
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let outline = CGMutablePath()
outline.move(to: CGPoint(x: 20, y: 13))
outline.addCurve(to: CGPoint(x: 12.34, y: 21.95), control1: CGPoint(x: 20, y: 18), control2: CGPoint(x: 16.5, y: 20.5))
outline.addQuadCurve(to: CGPoint(x: 11.67, y: 21.94), control: CGPoint(x: 12, y: 22.06))
outline.addCurve(to: CGPoint(x: 4, y: 13), control1: CGPoint(x: 7.5, y: 20.5), control2: CGPoint(x: 4, y: 18))
outline.addLine(to: CGPoint(x: 4, y: 6))
outline.addQuadCurve(to: CGPoint(x: 5, y: 5), control: CGPoint(x: 4, y: 5))
outline.addCurve(to: CGPoint(x: 11.24, y: 2.28), control1: CGPoint(x: 7, y: 5), control2: CGPoint(x: 9.5, y: 3.8))
outline.addQuadCurve(to: CGPoint(x: 12.76, y: 2.28), control: CGPoint(x: 12, y: 1.64))
outline.addCurve(to: CGPoint(x: 19, y: 5), control1: CGPoint(x: 14.51, y: 3.81), control2: CGPoint(x: 17, y: 5))
outline.addQuadCurve(to: CGPoint(x: 20, y: 6), control: CGPoint(x: 20, y: 5))
outline.closeSubpath()
outline.move(to: CGPoint(x: 9, y: 12))
outline.addLine(to: CGPoint(x: 11, y: 14))
outline.addLine(to: CGPoint(x: 15, y: 10))

for (name, red, green, blue) in [
    ("1024.png", 166.0, 22.0, 67.0),
    ("1024-dark.png", 37.0, 15.0, 27.0),
    ("1024-tinted.png", 0.0, 0.0, 0.0),
] {
    guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                  bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("Cannot create app icon bitmap") }
    context.setFillColor(CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.translateBy(x: 176, y: 848)
    context.scaleBy(x: 28, y: -28)
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(outline)
    context.strokePath()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot encode app icon") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write app icon") }
}
