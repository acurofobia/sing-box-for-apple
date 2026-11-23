import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Input: Vipin VPN's Android xxxhdpi adaptive foreground. Output: the iOS AppIcon set.
guard CommandLine.arguments.count == 3 else { fatalError("Usage: render.swift <foreground.png> <appiconset>") }
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
// Remove Android's adaptive mask padding to match the lettering in its 192 × 192 launcher icon.
guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil), image.width == 432, image.height == 432,
      let logo = image.cropping(to: CGRect(x: 104, y: 104, width: 224, height: 224))
else { fatalError("Expected the 432 × 432 Android foreground") }

let size = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
for (name, background, space, alpha) in [
    ("1024.png", CGColor(gray: 1, alpha: 1), srgb, CGImageAlphaInfo.noneSkipLast),
    ("1024-dark.png", CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1), srgb, .noneSkipLast),
    ("1024-tinted.png", CGColor(gray: 0, alpha: 1), gray, .none),
] {
    guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)
    else { fatalError("Cannot create bitmap for \(name)") }
    context.setFillColor(background)
    context.fill(size)
    context.interpolationQuality = .high
    context.draw(logo, in: size)
    guard let icon = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot encode \(name)") }
    CGImageDestinationAddImage(destination, icon, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(name)") }
}
