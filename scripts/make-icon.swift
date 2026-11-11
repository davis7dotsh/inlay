import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// Three fitted strokes form an inset I, matching Resources/Inlay.svg.
// Keep this geometry in sync with InlayBrand.logoPath(in:).
func logoPath() -> CGPath {
    let path = CGMutablePath()
    let strokes = [
        CGRect(x: 20, y: 20, width: 88, height: 16),
        CGRect(x: 56, y: 44, width: 16, height: 40),
        CGRect(x: 20, y: 92, width: 88, height: 16),
    ]
    for stroke in strokes {
        path.addRoundedRect(in: stroke, cornerWidth: 8, cornerHeight: 8)
    }
    return path
}

func color(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha).cgColor
}

func makeIcon(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    let graphics = context.cgContext
    graphics.translateBy(x: 0, y: CGFloat(pixels))
    graphics.scaleBy(x: CGFloat(pixels) / 512, y: -CGFloat(pixels) / 512)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGPath(roundedRect: CGRect(x: 12, y: 12, width: 488, height: 488),
                            cornerWidth: 112, cornerHeight: 112, transform: nil)
    let paper = CGGradient(colorsSpace: colorSpace, colors: [color(0xFCF9F2), color(0xE8D9D4)] as CFArray,
                           locations: [0, 1])!
    graphics.saveGState()
    graphics.addPath(background)
    graphics.clip()
    graphics.drawLinearGradient(paper, start: CGPoint(x: 80, y: 20), end: CGPoint(x: 420, y: 500),
                                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    graphics.restoreGState()

    let edge = CGPath(roundedRect: CGRect(x: 13, y: 13, width: 486, height: 486),
                      cornerWidth: 111, cornerHeight: 111, transform: nil)
    let edgeGradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [color(0xFFFFFF, alpha: 0.9), color(0x352D3A, alpha: 0.12)] as CFArray,
                                  locations: [0, 1])!
    graphics.saveGState()
    graphics.addPath(edge)
    graphics.setLineWidth(2)
    graphics.replacePathWithStrokedPath()
    graphics.clip()
    graphics.drawLinearGradient(edgeGradient, start: CGPoint(x: 180, y: 0), end: CGPoint(x: 300, y: 512),
                                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    graphics.restoreGState()

    graphics.translateBy(x: 83, y: 83)
    graphics.scaleBy(x: 2.7, y: 2.7)
    graphics.setFillColor(color(0x352D3A))
    graphics.addPath(logoPath())
    graphics.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try makeIcon(pixels: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try makeIcon(pixels: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
