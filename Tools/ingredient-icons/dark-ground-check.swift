import AppKit

// Composites a sample of the paintings onto the app's real light and dark
// porcelain grounds, bare and on a Surface.badge disc.
//
//   swift Tools/ingredient-icons/dark-ground-check.swift
//
// The set's README warns against dark grounds, so before deciding whether
// dark mode needs a disc behind every painting, look at one. Run from the
// repository root; writes the sheet into the ticket's captures folder.

let root = FileManager.default.currentDirectoryPath
let catalogue = "\(root)/Ladle/Resources/IngredientIcons.xcassets"
let output = "\(root)/docs/verification/captures/2026-09-02-ingredient-icons"
    + "/dark-ground-check.png"

let slugs = [
    "bay-leaf", "spinach", "kale", "basil-fresh", "cilantro", "chard",
    "beef-ground", "eggplant", "blackberry", "nigella-seeds",
    "cumin-seed", "soy-sauce", "black-pepper-ground", "garlic",
]

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let porcelainDark = rgb(0x101214)
let porcelainLight = rgb(0xF2F4F6)
let badgeDark = rgb(0x303840)

let art: CGFloat = 40          // the shipping row size, in points
let scale: CGFloat = 3         // drawn at 3x so the screenshot is readable
let cell = art * 2 * scale
let cols = CGFloat(slugs.count)
let rowH = cell + 22 * scale
let width = cols * cell
let height = rowH * 3

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

let font = NSFont.systemFont(ofSize: 9 * scale)

func band(_ index: CGFloat, ground: NSColor, disc: Bool, label: String, ink: NSColor) {
    let y = height - rowH * (index + 1)
    ground.setFill()
    NSRect(x: 0, y: y, width: width, height: rowH).fill()
    label.draw(
        at: NSPoint(x: 6 * scale, y: y + 6 * scale),
        withAttributes: [.font: font, .foregroundColor: ink]
    )
    for (column, slug) in slugs.enumerated() {
        let originX = CGFloat(column) * cell + (cell - art * scale) / 2
        let originY = y + 20 * scale
        if disc {
            badgeDark.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: originX, y: originY,
                    width: art * scale, height: art * scale
                )
            ).fill()
        }
        guard let file = NSImage(
            contentsOfFile: "\(catalogue)/\(slug).imageset/\(slug).png"
        ) else { continue }
        file.draw(
            in: NSRect(
                x: originX, y: originY,
                width: art * scale, height: art * scale
            )
        )
    }
}

band(0, ground: porcelainDark, disc: false, label: "DARK #101214 — bare", ink: .white)
band(1, ground: porcelainDark, disc: true, label: "DARK #101214 — on Surface.badge #303840", ink: .white)
band(2, ground: porcelainLight, disc: false, label: "LIGHT #F2F4F6 — bare (shipping)", ink: .black)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { exit(1) }
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output) \(Int(width))x\(Int(height))")
