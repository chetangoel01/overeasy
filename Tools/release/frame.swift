// Compose an App Store screenshot: a caption over a device-framed capture.
//
// Output is exactly 1320x2868 with no alpha, which is what App Store Connect's
// 6.9" slot accepts. Drawn with CoreGraphics so there is no dependency to
// install and no resampling of the capture beyond one clean downscale.
//
//   swift frame.swift SHOT.png OUT.png "Caption line one" ["line two"]
import AppKit
import CoreGraphics
import Foundation

let canvasWidth: CGFloat = 1320
let canvasHeight: CGFloat = 2868

// The app's palette, from Ladle/Resources/Assets.xcassets.
let paper = CGColor(red: 0.968, green: 0.957, blue: 0.937, alpha: 1)
let oat = CGColor(red: 0.925, green: 0.906, blue: 0.882, alpha: 1)
let ink = NSColor(red: 0.078, green: 0.094, blue: 0.106, alpha: 1)
let brick = NSColor(red: 0.933, green: 0.294, blue: 0.184, alpha: 1)

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: frame.swift SHOT.png OUT.png LINE1 [LINE2]\n".data(using: .utf8)!)
    exit(2)
}
let shotURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let lines = Array(args[3...])

guard let src = CGImageSourceCreateWithURL(shotURL as CFURL, nil),
      let shot = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("could not read \(shotURL.path)\n".data(using: .utf8)!)
    exit(1)
}

guard let ctx = CGContext(
    data: nil,
    width: Int(canvasWidth),
    height: Int(canvasHeight),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { exit(1) }

// Background: a soft vertical wash from paper to oat, so the device sits on
// something warmer than flat white without competing with the food.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
if let gradient = CGGradient(
    colorsSpace: space,
    colors: [paper, oat] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvasHeight),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
}

// --- Caption -------------------------------------------------------------
// Drawn through AppKit so the system font's real metrics apply.
let previous = NSGraphicsContext.current
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

let captionSize: CGFloat = lines.count > 1 ? 96 : 104
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
paragraph.lineSpacing = 8

let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: captionSize, weight: .bold),
    .foregroundColor: ink,
    .paragraphStyle: paragraph,
    .kern: -1.5,
]

let caption = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attributes)
let captionWidth = canvasWidth - 200
let captionBounds = caption.boundingRect(
    with: NSSize(width: captionWidth, height: .greatestFiniteMagnitude),
    options: [.usesLineFragmentOrigin, .usesFontLeading]
)
// CoreGraphics counts from the bottom, so a top margin is measured down from
// the canvas height.
let captionTop = canvasHeight - 190
caption.draw(with: NSRect(
    x: 100,
    y: captionTop - captionBounds.height,
    width: captionWidth,
    height: captionBounds.height
), options: [.usesLineFragmentOrigin, .usesFontLeading])

// A short rule under the caption, in the accent, to give the block a foot.
let ruleWidth: CGFloat = 96
let ruleY = captionTop - captionBounds.height - 54
ctx.setFillColor(brick.cgColor)
ctx.fill(CGRect(x: (canvasWidth - ruleWidth) / 2, y: ruleY, width: ruleWidth, height: 8))

NSGraphicsContext.current = previous

// --- Device --------------------------------------------------------------
let deviceWidth: CGFloat = 960
let deviceHeight = deviceWidth * (CGFloat(shot.height) / CGFloat(shot.width))
let deviceX = (canvasWidth - deviceWidth) / 2
// CoreGraphics counts up from the bottom, so the device's *top* edge is
// deviceY + deviceHeight. Placing it a fixed gap under the rule is the only
// way to guarantee it never rides up over the caption.
let deviceY = ruleY - 90 - deviceHeight
let deviceRect = CGRect(x: deviceX, y: deviceY, width: deviceWidth, height: deviceHeight)
let corner: CGFloat = 132

ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -24),
    blur: 60,
    color: CGColor(red: 0.15, green: 0.11, blue: 0.08, alpha: 0.28)
)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(CGPath(roundedRect: deviceRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: deviceRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.clip()
ctx.draw(shot, in: deviceRect)
ctx.restoreGState()

// A hairline edge so the capture's own light background never bleeds into the
// page background.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: deviceRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.setStrokeColor(CGColor(red: 0.15, green: 0.11, blue: 0.08, alpha: 0.16))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("\(outURL.lastPathComponent) \(Int(canvasWidth))x\(Int(canvasHeight))")
