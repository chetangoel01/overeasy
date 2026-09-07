// Draw the plant-based app icon candidates for issue #92.
//
//   swift Tools/app-icon/candidates.swift [OUT_DIR]
//
// Writes six 1024x1024 candidate PNGs plus contact-sheet.png into OUT_DIR
// (default design/board/icon-candidates). Every mark is CoreGraphics
// geometry rather than a picture, so the direction that gets picked is
// refined by editing its drawing function and re-running this, not by
// redrawing it somewhere else.
//
// The construction is measured off the shipping icon
// (Ladle/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png): a
// full-bleed plum ground with a soft radial lift, flat fills with no outline
// anywhere, one soft drop shadow under the main mass, an offset darker copy
// of a shape as its contact shadow, and one small warm highlight. The
// measurements are written up in
// docs/plans/2026-09-07-plant-based-icon-candidates.md.
import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette
//
// Ground, warm white, yolk and highlight are sampled from the shipping icon;
// it predates DESIGN.md and does not use the Porcelain & Graphite values.
// Green is `Celery` from Assets.xcassets (#83A18A), with a shade at 0.72x,
// mirroring the yolk's own fill-to-shade ratio.

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let groundLift = rgb(0x4C3B46)   // measured near the top centre
let groundEdge = rgb(0x3C2E37)   // measured at the corners
let warmWhite = rgb(0xFCF9F2)    // the egg white
let warmDeep = rgb(0xE4D9C8)     // porcelain in shadow
let highlight = rgb(0xF8EBDF)    // the yolk's one specular ellipse
let yolk = rgb(0xD8622E)
let leafGreen = rgb(0x83A18A)    // Celery
let leafLight = rgb(0x9CB9A3)
let leafDeep = rgb(0x5E7463)     // Celery x 0.72
let leafShade = rgb(0x48584C)    // Celery x 0.55, contact only
let rind = rgb(0x33473A)
let stone = rgb(0xA8431F)
let stoneShade = rgb(0x7C3013)

// MARK: - Drawing helpers

/// An almond leaf between two points, bulging a fraction of its own length to
/// each side. Two quadratic arcs, because a leaf is two arcs.
func leafPath(base: CGPoint, tip: CGPoint, bulge: CGFloat, backBulge: CGFloat? = nil) -> CGPath {
    let dx = tip.x - base.x
    let dy = tip.y - base.y
    let length = max(hypot(dx, dy), 0.001)
    let nx = -dy / length
    let ny = dx / length
    let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
    let front = length * bulge * 2
    let back = length * (backBulge ?? bulge) * 2
    let path = CGMutablePath()
    path.move(to: base)
    path.addQuadCurve(to: tip, control: CGPoint(x: mid.x + nx * front, y: mid.y + ny * front))
    path.addQuadCurve(to: base, control: CGPoint(x: mid.x - nx * back, y: mid.y - ny * back))
    path.closeSubpath()
    return path
}

/// A round-capped bar. Every stem, handle and vein here is one of these: at
/// 60 px a bar thinner than about 40 units disappears, so they are fat.
func bar(from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
    let line = CGMutablePath()
    line.move(to: a)
    line.addLine(to: b)
    return line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func curvedBar(from a: CGPoint, control: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
    let line = CGMutablePath()
    line.move(to: a)
    line.addQuadCurve(to: b, control: control)
    return line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// How far a ray from `origin` in unit direction `direction` travels before it
/// leaves the circle. The roundel's veins use it so no vein can ever reach the
/// rim and cut a notch out of the silhouette, whatever length is asked for.
func distanceToRim(
    from origin: CGPoint,
    direction: CGPoint,
    centre: CGPoint,
    radius: CGFloat
) -> CGFloat {
    let fx = origin.x - centre.x
    let fy = origin.y - centre.y
    let b = fx * direction.x + fy * direction.y
    let c = fx * fx + fy * fy - radius * radius
    let discriminant = b * b - c
    return discriminant <= 0 ? 0 : -b + sqrt(discriminant)
}

func disc(_ centre: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(
        ellipseIn: CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        ),
        transform: nil
    )
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath()
}

/// The yolk's trick: the same shape, in a darker fill, pushed down a little
/// and drawn first. It is a contact shadow, not a stroke — the shipping icon
/// has no strokes at all.
func contact(
    _ ctx: CGContext,
    _ path: CGPath,
    _ color: CGColor,
    dy: CGFloat,
    dx: CGFloat = 0,
    grow: CGFloat = 1
) {
    let box = path.boundingBox
    var transform = CGAffineTransform(translationX: box.midX + dx, y: box.midY + dy)
        .scaledBy(x: grow, y: grow)
        .translatedBy(x: -box.midX, y: -box.midY)
    guard let moved = path.copy(using: &transform) else { return }
    fill(ctx, moved, color)
}

/// The soft shadow the egg white casts on the ground. Wraps the main mass
/// only; elements sitting on top of the mass use `contact` instead.
func withDropShadow(_ ctx: CGContext, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 16, height: 22),
        blur: 54,
        color: CGColor(red: 0.07, green: 0.04, blue: 0.06, alpha: 0.38)
    )
    // A transparency layer so one shadow is cast by the whole mass rather
    // than by each shape in it, which would print shadows inside the mark.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// The tilted specular ellipse quoted from the yolk.
func speck(
    _ ctx: CGContext,
    at centre: CGPoint,
    size: CGSize,
    angle: CGFloat,
    color: CGColor = highlight
) {
    ctx.saveGState()
    ctx.translateBy(x: centre.x, y: centre.y)
    ctx.rotate(by: angle)
    fill(
        ctx,
        CGPath(
            ellipseIn: CGRect(
                x: -size.width / 2,
                y: -size.height / 2,
                width: size.width,
                height: size.height
            ),
            transform: nil
        ),
        color
    )
    ctx.restoreGState()
}

func ground(_ ctx: CGContext, _ side: CGFloat) {
    ctx.setFillColor(groundEdge)
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [groundLift, groundEdge] as CFArray,
        locations: [0, 1]
    ) else { return }
    // The lift sits above centre, which is where the shipping icon's is.
    ctx.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: side * 0.5, y: side * 0.78),
        startRadius: 0,
        endCenter: CGPoint(x: side * 0.5, y: side * 0.78),
        endRadius: side * 0.96,
        options: [.drawsAfterEndLocation]
    )
}

// MARK: - Candidates
//
// All geometry below is written top-down in a 1024 square: y grows downward,
// so the numbers match how the shipping icon was measured. `render` installs
// the flip.

struct Candidate {
    let slug: String
    let title: String
    let draw: (CGContext) -> Void
}

/// 1 — Sprout. Two cotyledons on a fat stem: the plainest statement that
/// this is the same app without the egg in it.
func drawSprout(_ ctx: CGContext) {
    let stem = curvedBar(
        from: CGPoint(x: 512, y: 812),
        control: CGPoint(x: 466, y: 664),
        to: CGPoint(x: 512, y: 520),
        width: 56
    )
    let left = leafPath(
        base: CGPoint(x: 508, y: 560),
        tip: CGPoint(x: 214, y: 372),
        bulge: 0.30,
        backBulge: 0.13
    )
    let right = leafPath(
        base: CGPoint(x: 516, y: 528),
        tip: CGPoint(x: 826, y: 306),
        bulge: 0.14,
        backBulge: 0.31
    )
    withDropShadow(ctx) {
        contact(ctx, left, leafShade, dy: 22)
        contact(ctx, right, leafShade, dy: 22)
        contact(ctx, stem, leafShade, dy: 18)
        fill(ctx, stem, leafDeep)
        fill(ctx, left, leafGreen)
        fill(ctx, right, leafLight)
    }
    speck(ctx, at: CGPoint(x: 702, y: 358), size: CGSize(width: 80, height: 42), angle: 0.60)
}

/// 2 — Bowl. The porcelain of the design system, heaped with greens: the
/// object the app is about rather than an ingredient in it.
func drawBowl(_ ctx: CGContext) {
    let rimY: CGFloat = 588
    let bowl = CGMutablePath()
    bowl.move(to: CGPoint(x: 196, y: rimY))
    bowl.addLine(to: CGPoint(x: 828, y: rimY))
    bowl.addCurve(
        to: CGPoint(x: 196, y: rimY),
        control1: CGPoint(x: 806, y: 902),
        control2: CGPoint(x: 218, y: 902)
    )
    bowl.closeSubpath()

    let foot = CGPath(
        roundedRect: CGRect(x: 412, y: 806, width: 200, height: 48),
        cornerWidth: 24,
        cornerHeight: 24,
        transform: nil
    )

    let mound = CGMutablePath()
    mound.move(to: CGPoint(x: 234, y: rimY - 2))
    mound.addCurve(
        to: CGPoint(x: 790, y: rimY - 2),
        control1: CGPoint(x: 286, y: 366),
        control2: CGPoint(x: 738, y: 366)
    )
    mound.closeSubpath()

    // Lobes on the dome, so the heap has the bumpy edge of greens in a bowl
    // rather than the smooth edge of a lid. Uneven on purpose.
    let lobes = [
        (CGPoint(x: 332, y: 494), CGFloat(84)),
        (CGPoint(x: 462, y: 456), CGFloat(98)),
        (CGPoint(x: 606, y: 464), CGFloat(90)),
        (CGPoint(x: 726, y: 508), CGFloat(76)),
    ].map { disc($0.0, $0.1) }

    // Three sprigs at three different lengths and angles: two symmetric ones
    // read as a pair of ears, which is the trap this shape falls into.
    let sprigs = [
        leafPath(base: CGPoint(x: 442, y: 500), tip: CGPoint(x: 222, y: 282), bulge: 0.30, backBulge: 0.12),
        leafPath(base: CGPoint(x: 522, y: 486), tip: CGPoint(x: 578, y: 198), bulge: 0.20, backBulge: 0.20),
        leafPath(base: CGPoint(x: 610, y: 500), tip: CGPoint(x: 812, y: 340), bulge: 0.12, backBulge: 0.30),
    ]
    let sprigFills = [leafDeep, leafLight, leafGreen]

    withDropShadow(ctx) {
        for sprig in sprigs { contact(ctx, sprig, leafShade, dy: 20) }
        for (sprig, colour) in zip(sprigs, sprigFills) { fill(ctx, sprig, colour) }
        fill(ctx, mound, leafGreen)
        for lobe in lobes { fill(ctx, lobe, leafGreen) }
        fill(ctx, foot, warmDeep)
        fill(ctx, bowl, warmWhite)
    }
    // The greens sit in the bowl, so the bowl casts onto them and not the
    // other way round: one dark band along the rim is what that looks like.
    ctx.saveGState()
    ctx.addPath(mound)
    ctx.clip()
    fill(
        ctx,
        CGPath(rect: CGRect(x: 196, y: rimY - 28, width: 632, height: 28), transform: nil),
        leafDeep
    )
    ctx.restoreGState()
    speck(
        ctx,
        at: CGPoint(x: 342, y: 700),
        size: CGSize(width: 140, height: 60),
        angle: -0.40,
        color: warmDeep
    )
}

/// 3 — Skillet. The pan the egg used to be cooked in, seen from above, with
/// greens in it instead. Enamel white so the icon keeps the egg's white mass.
func drawSkillet(_ ctx: CGContext) {
    let centre = CGPoint(x: 452, y: 560)
    let pan = disc(centre, 292)
    let angle: CGFloat = -0.52  // up and to the right
    let handle = bar(
        from: CGPoint(x: centre.x + cos(angle) * 236, y: centre.y + sin(angle) * 236),
        to: CGPoint(x: centre.x + cos(angle) * 452, y: centre.y + sin(angle) * 452),
        width: 84
    )
    // A heap, not a rosette: one off-centre root, uneven lengths, and a gap
    // in the fan. Evenly spaced leaves around a centre read as a flower.
    let root = CGPoint(x: centre.x - 18, y: centre.y + 42)
    let sprigs: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
        (-160, 200, 0.24, leafDeep),
        (-118, 216, 0.28, leafGreen),
        (-72, 194, 0.22, leafLight),
        (-30, 206, 0.27, leafGreen),
        (16, 158, 0.23, leafDeep),
    ]
    let greens = sprigs.map { degrees, length, bulge, _ -> CGPath in
        let theta = degrees * .pi / 180
        return leafPath(
            base: root,
            tip: CGPoint(x: root.x + cos(theta) * length, y: root.y + sin(theta) * length),
            bulge: bulge,
            backBulge: bulge
        )
    }
    withDropShadow(ctx) {
        fill(ctx, handle, yolk)
        fill(ctx, pan, warmWhite)
    }
    // The cooking surface: one step darker than the enamel rim.
    fill(ctx, disc(centre, 238), warmDeep)
    for (green, sprig) in zip(greens, sprigs) {
        contact(ctx, green, leafShade, dy: 16)
        fill(ctx, green, sprig.3)
    }
    // One bead of oil, standing in for the yolk's single specular ellipse.
    speck(ctx, at: CGPoint(x: 386, y: 470), size: CGSize(width: 60, height: 32), angle: 0.72)
}

/// 4 — Lettuce. A rosette of overlapping leaves: produce, drawn as one solid
/// silhouette so the scalloped edge is the whole idea.
func drawLettuce(_ ctx: CGContext) {
    let centre = CGPoint(x: 512, y: 528)
    func ring(count: Int, radius: CGFloat, phase: CGFloat, width: CGFloat) -> [CGPath] {
        (0..<count).map { index in
            let t = phase + CGFloat(index) / CGFloat(count) * 2 * .pi
            return leafPath(
                base: CGPoint(x: centre.x - cos(t) * radius * 0.20, y: centre.y - sin(t) * radius * 0.20),
                tip: CGPoint(x: centre.x + cos(t) * radius, y: centre.y + sin(t) * radius),
                bulge: width,
                backBulge: width
            )
        }
    }
    // Fat, blunt lobes rather than pointed leaves: a pointed rosette reads as
    // a flower or a succulent, and this has to read as something you eat.
    let outer = ring(count: 7, radius: 318, phase: 0.24, width: 0.44)
    let middle = ring(count: 6, radius: 234, phase: 0.94, width: 0.46)
    let inner = ring(count: 5, radius: 152, phase: 0.42, width: 0.48)
    // Three clearly separated tones. The first pass stepped by one shade per
    // ring and at 60 px the whole head collapsed into one green polygon.
    withDropShadow(ctx) {
        for path in outer { fill(ctx, path, rgb(0x4A5F51)) }
    }
    for path in middle { fill(ctx, path, leafGreen) }
    for path in inner { fill(ctx, path, rgb(0xB7CDBD)) }
    // The heart of the head. No speck: a bright dot dead centre of a rosette
    // reads as an eye.
    fill(ctx, disc(centre, 44), rgb(0xC6D8CB))
}

/// 5 — Roundel. The disc is the only geometric primitive in the shipping
/// icon; this keeps it at the yolk's own centre and turns it into a leaf by
/// subtraction, so the app's accent shape does the work.
func drawRoundel(_ ctx: CGContext) {
    let centre = CGPoint(x: 512, y: 496)
    let radius: CGFloat = 312
    let body = disc(centre, radius)
    // The stalk runs out from under the disc, so the mark is a leaf and not
    // a badge with a stick next to it.
    let stalk = bar(
        from: CGPoint(x: centre.x - 190, y: centre.y + 190),
        to: CGPoint(x: centre.x - 362, y: centre.y + 362),
        width: 60
    )
    withDropShadow(ctx) {
        contact(ctx, body, leafShade, dy: 24)
        contact(ctx, stalk, leafShade, dy: 20)
        fill(ctx, stalk, leafDeep)
        fill(ctx, body, leafGreen)
    }
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    // Midrib on the icon's own diagonal, then three pairs of veins off it.
    // The channels are ground-coloured, so the leaf is cut out of the disc.
    // Three pairs, not five: at 60 px more than that is texture, not a leaf.
    let base = CGPoint(x: centre.x - 268, y: centre.y + 268)
    let tip = CGPoint(x: centre.x + 178, y: centre.y - 178)
    fill(ctx, bar(from: base, to: tip, width: 58), groundEdge)
    for step in stride(from: CGFloat(0.34), through: CGFloat(0.91), by: CGFloat(0.28)) {
        let anchor = CGPoint(
            x: base.x + (tip.x - base.x) * step,
            y: base.y + (tip.y - base.y) * step
        )
        // The two directions are the midrib rotated +-55 degrees, so the
        // pair is symmetric about it.
        for direction in [CGPoint(x: 0.985, y: 0.174), CGPoint(x: -0.174, y: -0.985)] {
            let rim = distanceToRim(from: anchor, direction: direction, centre: centre, radius: radius)
            let reach = min(224 * (1 - step * 0.44), rim - 58)
            guard reach > 40 else { continue }
            fill(
                ctx,
                bar(
                    from: anchor,
                    to: CGPoint(x: anchor.x + direction.x * reach, y: anchor.y + direction.y * reach),
                    width: 46
                ),
                groundEdge
            )
        }
    }
    ctx.restoreGState()
}

/// 6 — Avocado. The shipping icon's composition exactly — one organic mass,
/// one round centre, one speck on it — with nothing of the egg left in it.
/// The rind band is deliberately thick so the silhouette is green at 60 px.
func drawAvocado(_ ctx: CGContext) {
    // A real neck. The first pass was a plain teardrop with a round centre,
    // which at 60 px is a fried egg; the narrow shoulder is what stops that.
    let outer = CGMutablePath()
    outer.move(to: CGPoint(x: 512, y: 190))
    outer.addCurve(
        to: CGPoint(x: 714, y: 598),
        control1: CGPoint(x: 578, y: 200),
        control2: CGPoint(x: 708, y: 392)
    )
    outer.addCurve(
        to: CGPoint(x: 512, y: 886),
        control1: CGPoint(x: 726, y: 776),
        control2: CGPoint(x: 652, y: 886)
    )
    outer.addCurve(
        to: CGPoint(x: 310, y: 598),
        control1: CGPoint(x: 372, y: 886),
        control2: CGPoint(x: 298, y: 776)
    )
    outer.addCurve(
        to: CGPoint(x: 512, y: 190),
        control1: CGPoint(x: 316, y: 392),
        control2: CGPoint(x: 446, y: 200)
    )
    outer.closeSubpath()

    let box = outer.boundingBox
    var inset = CGAffineTransform(translationX: box.midX, y: box.midY + 18)
        .scaledBy(x: 0.76, y: 0.82)
        .translatedBy(x: -box.midX, y: -box.midY)
    let flesh = outer.copy(using: &inset)!

    let pit = CGPoint(x: 512, y: 636)
    ctx.saveGState()
    // A small tilt: the shipping icon's blob is not axis-symmetric either,
    // and a bolt-upright pear is the most egg-like thing this could be.
    ctx.translateBy(x: 512, y: 540)
    ctx.rotate(by: 0.09)
    ctx.translateBy(x: -512, y: -540)
    withDropShadow(ctx) {
        fill(ctx, outer, rind)
    }
    fill(ctx, flesh, rgb(0xC3D0A8))          // flesh is yellow-green, not porcelain
    fill(ctx, disc(pit, 122), rgb(0x7E9270))  // the socket the stone sits in
    contact(ctx, disc(pit, 94), stoneShade, dy: 10, grow: 1.08)
    fill(ctx, disc(pit, 94), stone)
    speck(ctx, at: CGPoint(x: 480, y: 604), size: CGSize(width: 66, height: 40), angle: 0.55)
    ctx.restoreGState()
}

let candidates: [Candidate] = [
    Candidate(slug: "01-sprout", title: "1 · Sprout", draw: drawSprout),
    Candidate(slug: "02-bowl", title: "2 · Bowl", draw: drawBowl),
    Candidate(slug: "03-skillet", title: "3 · Skillet", draw: drawSkillet),
    Candidate(slug: "04-lettuce", title: "4 · Lettuce", draw: drawLettuce),
    Candidate(slug: "05-roundel", title: "5 · Roundel", draw: drawRoundel),
    Candidate(slug: "06-avocado", title: "6 · Avocado", draw: drawAvocado),
]

// MARK: - Rendering

let side: CGFloat = 1024

func newContext(width: Int, height: Int) -> CGContext {
    // noneSkipLast: an app icon must not carry an alpha channel, and the
    // shipping AppIcon.png does not.
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("could not create a \(width)x\(height) context") }
    return ctx
}

func render(_ candidate: Candidate) -> CGImage {
    let ctx = newContext(width: Int(side), height: Int(side))
    ground(ctx, side)
    ctx.saveGState()
    // Work top-down, the way the shipping icon was measured.
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    candidate.draw(ctx)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { fatalError("could not open \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("design/board/icon-candidates")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var sheetRows: [(String, CGImage)] = []

let currentURL = root.appendingPathComponent(
    "Ladle/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)
if let source = CGImageSourceCreateWithURL(currentURL as CFURL, nil),
   let current = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    sheetRows.append(("Current · fried egg (shipping)", current))
} else {
    FileHandle.standardError.write("warning: could not read the shipping icon\n".data(using: .utf8)!)
}

for candidate in candidates {
    let image = render(candidate)
    writePNG(image, to: outDir.appendingPathComponent("\(candidate.slug).png"))
    print("\(candidate.slug).png 1024x1024")
    sheetRows.append((candidate.title, image))
}

// MARK: - Contact sheet
//
// The 180 and 60 cells are the 1024 master resampled, not redrawn small,
// because resampling one master is exactly what iOS does with a single-size
// appiconset. Cells are masked to the home-screen shape so legibility is
// judged on the shape a cook actually sees.

let sizes: [CGFloat] = [1024, 180, 60]
let margin: CGFloat = 64
let colGap: CGFloat = 56
let rowGap: CGFloat = 72
let labelBand: CGFloat = 52
let headerBand: CGFloat = 104

let sheetWidth = margin * 2 + sizes.reduce(0, +) + colGap * CGFloat(sizes.count - 1)
let rowHeight = labelBand + sizes[0]
let sheetHeight = margin * 2 + headerBand
    + rowHeight * CGFloat(sheetRows.count)
    + rowGap * CGFloat(max(sheetRows.count - 1, 0))

let sheet = newContext(width: Int(sheetWidth), height: Int(sheetHeight))
sheet.setFillColor(rgb(0xF2F4F6))
sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

let previousContext = NSGraphicsContext.current
NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)

/// Text placed by its top-left corner in a top-down sheet coordinate system.
func text(_ string: String, at topLeft: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
    attributed.draw(at: NSPoint(x: topLeft.x, y: sheetHeight - topLeft.y - attributed.size().height))
}

let inkColor = NSColor(red: 0.078, green: 0.094, blue: 0.106, alpha: 1)
let mutedColor = NSColor(red: 0.392, green: 0.439, blue: 0.478, alpha: 1)

text(
    "Overeasy · plant-based app icon candidates · issue #92",
    at: CGPoint(x: margin, y: margin),
    size: 32,
    weight: .semibold,
    color: inkColor
)
text(
    "Each row: the 1024 master, then 180 px and 60 px resampled from it. Home-screen mask applied.",
    at: CGPoint(x: margin, y: margin + 44),
    size: 20,
    weight: .regular,
    color: mutedColor
)

var columnX: [CGFloat] = []
var cursor = margin
for size in sizes {
    columnX.append(cursor)
    cursor += size + colGap
}

for (index, row) in sheetRows.enumerated() {
    let rowTop = margin + headerBand + (rowHeight + rowGap) * CGFloat(index)
    text(row.0, at: CGPoint(x: margin, y: rowTop), size: 26, weight: .semibold, color: inkColor)
    for (column, size) in sizes.enumerated() {
        let top = rowTop + labelBand + (sizes[0] - size) / 2
        let rect = CGRect(x: columnX[column], y: sheetHeight - top - size, width: size, height: size)
        sheet.saveGState()
        sheet.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: size * 0.2237,
            cornerHeight: size * 0.2237,
            transform: nil
        ))
        sheet.clip()
        sheet.interpolationQuality = .high
        sheet.draw(row.1, in: rect)
        sheet.restoreGState()
        if index == 0 {
            text(
                "\(Int(size)) px",
                at: CGPoint(x: columnX[column], y: rowTop + labelBand - 32),
                size: 19,
                weight: .medium,
                color: mutedColor
            )
        }
    }
}

NSGraphicsContext.current = previousContext

writePNG(sheet.makeImage()!, to: outDir.appendingPathComponent("contact-sheet.png"))
print("contact-sheet.png \(Int(sheetWidth))x\(Int(sheetHeight))")
