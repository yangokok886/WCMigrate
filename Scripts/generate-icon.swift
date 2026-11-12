// WCMigrate native vector icon. No remote images or trademark artwork.
// Run: swift -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk Scripts/generate-icon.swift OUTPUT.png
import AppKit
let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [CGColor(red: 0.025, green: 0.12, blue: 0.135, alpha: 1), CGColor(red: 0.045, green: 0.27, blue: 0.26, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
func arrow(_ points: [CGPoint], color: CGColor) {
    context.beginPath(); context.addLines(between: points); context.closePath(); context.setFillColor(color); context.fillPath()
}
arrow([.init(x: 222,y: 544),.init(x: 222,y: 674),.init(x: 612,y: 674),.init(x: 612,y: 784),.init(x: 814,y: 608),.init(x: 612,y: 432),.init(x: 612,y: 544)], color: CGColor(red: 0.47, green: 0.96, blue: 0.77, alpha: 1))
arrow([.init(x: 802,y: 480),.init(x: 802,y: 350),.init(x: 412,y: 350),.init(x: 412,y: 240),.init(x: 210,y: 416),.init(x: 412,y: 592),.init(x: 412,y: 480)], color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
