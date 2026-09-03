// Redraw a PNG onto opaque white and re-save as PNG.
// App Store Connect rejects screenshots that carry an alpha channel, and
// simctl always writes one even though every pixel is opaque.
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("usage: flatten.swift IN.png OUT.png\n".data(using: .utf8)!)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("could not read \(inputURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let width = image.width
let height = image.height

guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    // noneSkipLast is what drops the alpha channel: the stored image has no
    // alpha at all rather than an alpha that happens to be opaque.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write("could not create context\n".data(using: .utf8)!)
    exit(1)
}

context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

guard let flattened = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, "public.png" as CFString, 1, nil
      ) else {
    FileHandle.standardError.write("could not create output\n".data(using: .utf8)!)
    exit(1)
}

CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("could not write \(outputURL.path)\n".data(using: .utf8)!)
    exit(1)
}

print("\(outputURL.lastPathComponent) \(width)x\(height)")
