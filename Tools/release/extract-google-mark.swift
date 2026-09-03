// Lift Google's "G" off the flat pill it ships on, so it can sit on our own
// button background instead of carrying Google's with it.
//
//   swift keyg.swift SOURCE.png OUT.png cropX cropY cropSide
//
// The source is Google's supplied sign-in button, whose background is a
// single flat colour. For a pixel P over background B, P = a*F + (1-a)*B, so
// distance from B recovers the alpha and unpremultiplying recovers the
// colour. That keeps the antialiased edges clean rather than leaving a grey
// halo the way a hard threshold would.
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 6,
      let cropX = Int(args[3]), let cropY = Int(args[4]),
      let side = Int(args[5]) else {
    FileHandle.standardError.write(
        "usage: keyg.swift SOURCE.png OUT.png cropX cropY cropSide\n"
            .data(using: .utf8)!
    )
    exit(2)
}

guard let src = CGImageSourceCreateWithURL(
    URL(fileURLWithPath: args[1]) as CFURL, nil
), let full = CGImageSourceCreateImageAtIndex(src, 0, nil),
   let cropped = full.cropping(
       to: CGRect(x: cropX, y: cropY, width: side, height: side)
   ) else {
    FileHandle.standardError.write("could not read or crop source\n".data(using: .utf8)!)
    exit(1)
}

let w = cropped.width, h = cropped.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(
    data: &pixels, width: w, height: h,
    bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

// The corner is guaranteed to be pill, never glyph.
let bg = (r: Double(pixels[0]), g: Double(pixels[1]), b: Double(pixels[2]))

for index in stride(from: 0, to: pixels.count, by: 4) {
    let r = Double(pixels[index])
    let g = Double(pixels[index + 1])
    let b = Double(pixels[index + 2])

    let distance = max(abs(r - bg.r), max(abs(g - bg.g), abs(b - bg.b))) / 255
    // A small ramp rather than a step: edge pixels are genuinely part
    // background, and keeping their partial alpha is what stops the mark
    // looking cut out with scissors.
    let alpha = min(1, max(0, (distance - 0.02) / 0.18))

    if alpha <= 0 {
        pixels[index] = 0; pixels[index + 1] = 0
        pixels[index + 2] = 0; pixels[index + 3] = 0
        continue
    }

    // Unpremultiply against the known background to recover the mark's own
    // colour, then store premultiplied as the context expects.
    func recover(_ observed: Double, _ background: Double) -> UInt8 {
        let value = (observed - (1 - alpha) * background) / alpha
        return UInt8(max(0, min(255, value.rounded())) * alpha)
    }
    pixels[index] = recover(r, bg.r)
    pixels[index + 1] = recover(g, bg.g)
    pixels[index + 2] = recover(b, bg.b)
    pixels[index + 3] = UInt8((alpha * 255).rounded())
}

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil
      ) else { exit(1) }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("\(args[2]) \(w)x\(h) background \(Int(bg.r)),\(Int(bg.g)),\(Int(bg.b))")
