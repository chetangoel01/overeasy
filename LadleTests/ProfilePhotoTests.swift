import UIKit
import XCTest
@testable import Ladle

/// The device half of choosing a profile photo: crop, downscale, encode.
///
/// Every assertion here is on pixels rather than points, because the renderer
/// is pinned to a scale of 1 on purpose — left at the screen's scale the same
/// code would produce a 1024- or 1536-pixel image depending on the device
/// running the test, and four to nine times the bytes.
final class ProfilePhotoTests: XCTestCase {
    func testALandscapePhotoIsSquaredTo512Pixels() throws {
        let wide = Self.image(width: 1600, height: 900)

        let squared = ProfilePhoto.square(wide)

        let bitmap = try XCTUnwrap(squared.cgImage)
        XCTAssertEqual(bitmap.width, 512)
        XCTAssertEqual(bitmap.height, 512)
    }

    func testAPortraitPhotoIsSquaredTo512Pixels() throws {
        let tall = Self.image(width: 900, height: 1600)

        let bitmap = try XCTUnwrap(ProfilePhoto.square(tall).cgImage)

        XCTAssertEqual(bitmap.width, 512)
        XCTAssertEqual(bitmap.height, 512)
    }

    /// The centre, not a corner. The source is a white 3:1 field with one
    /// narrow red stripe down the middle: a centre crop keeps the stripe and
    /// white edges, while a crop anchored at a corner would be all white.
    func testTheSquareIsTakenFromTheCentre() throws {
        let striped = Self.stripedWide()

        let squared = ProfilePhoto.square(striped)

        XCTAssertEqual(Self.colour(of: squared, atX: 0.5, y: 0.5), .red)
        XCTAssertEqual(Self.colour(of: squared, atX: 0.02, y: 0.5), .white)
        XCTAssertEqual(Self.colour(of: squared, atX: 0.98, y: 0.5), .white)
    }

    /// A photo taken in portrait is stored landscape with an orientation tag,
    /// and only drawing honours it. Cropping the backing bitmap instead would
    /// square the wrong axis and hand back a rotated face.
    ///
    /// The source is split red over white. Squared as it stands, the split
    /// runs across the result; squared after a quarter turn it runs down it,
    /// and which way round the turn goes does not matter — what matters is
    /// that the turn reached the crop at all.
    func testOrientationIsAppliedBeforeTheCrop() throws {
        let halved = Self.halvedWide()
        let turned = UIImage(
            cgImage: try XCTUnwrap(halved.cgImage),
            scale: 1,
            orientation: .right
        )

        let upright = ProfilePhoto.square(halved)
        let squared = ProfilePhoto.square(turned)

        XCTAssertEqual(Self.colour(of: upright, atX: 0.5, y: 0.1), .red)
        XCTAssertEqual(Self.colour(of: upright, atX: 0.5, y: 0.9), .white)

        let left = Self.colour(of: squared, atX: 0.1, y: 0.5)
        let right = Self.colour(of: squared, atX: 0.9, y: 0.5)
        XCTAssertTrue(
            (left == .red && right == .white)
                || (left == .white && right == .red),
            "The split turned with the image: left \(left), right \(right)"
        )
        XCTAssertEqual(
            Self.colour(of: squared, atX: 0.1, y: 0.1),
            Self.colour(of: squared, atX: 0.1, y: 0.9),
            "...and is no longer a horizontal split"
        )
    }

    func testAnOrdinaryPhotoEncodesWellUnderTheCap() throws {
        let photo = Self.image(width: 4032, height: 3024)

        let jpeg = try XCTUnwrap(ProfilePhoto.jpeg(from: photo))

        XCTAssertLessThanOrEqual(jpeg.count, ProfilePhoto.maximumBytes)
        XCTAssertGreaterThan(jpeg.count, 0)
    }

    /// The quality steps down until the bytes fit. Driven with a cap far
    /// below anything a real photo needs, because a picture that overflows
    /// 512 KiB at 512 square is hard to construct and the loop is the same.
    func testQualityStepsDownUntilTheBytesFit() throws {
        let noisy = Self.noise()
        let first = try XCTUnwrap(
            ProfilePhoto.square(noisy).jpegData(
                compressionQuality: try XCTUnwrap(ProfilePhoto.qualities.first)
            )
        )
        let cap = first.count / 2

        let jpeg = try XCTUnwrap(
            ProfilePhoto.jpeg(from: noisy, maximumBytes: cap)
        )

        XCTAssertLessThanOrEqual(jpeg.count, cap)
        XCTAssertLessThan(jpeg.count, first.count)
    }

    /// Nil rather than an upload the server would refuse. A cap of one byte
    /// is the only way to reach it; the cook is told the photo did not save.
    func testAnImpossibleCapRefusesRatherThanOverflowing() {
        XCTAssertNil(
            ProfilePhoto.jpeg(from: Self.noise(), maximumBytes: 1)
        )
    }

    // MARK: - Sources

    private static func image(width: Int, height: Int) -> UIImage {
        renderer(width: width, height: height).image { context in
            UIColor.systemTeal.setFill()
            context.fill(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
        }
    }

    /// White, with a narrow red stripe down the middle. Narrow on purpose:
    /// the centre square of a 3:1 field is its middle third, so a stripe a
    /// third wide would fill the whole result and prove nothing.
    private static func stripedWide() -> UIImage {
        let width = 1200
        let height = 400
        return renderer(width: width, height: height).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.red.setFill()
            context.fill(
                CGRect(
                    x: width * 45 / 100,
                    y: 0,
                    width: width / 10,
                    height: height
                )
            )
        }
    }

    /// Red over white, split across the middle.
    private static func halvedWide() -> UIImage {
        let width = 1200
        let height = 400
        return renderer(width: width, height: height).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.red.setFill()
            context.fill(
                CGRect(x: 0, y: 0, width: width, height: height / 2)
            )
        }
    }

    /// Random pixels, which JPEG cannot compress away — the one source that
    /// makes the quality loop do anything.
    private static func noise() -> UIImage {
        let side = 512
        var generator = SystemRandomNumberGenerator()
        return renderer(width: side, height: side).image { context in
            for x in stride(from: 0, to: side, by: 2) {
                for y in stride(from: 0, to: side, by: 2) {
                    UIColor(
                        red: .random(in: 0 ... 1, using: &generator),
                        green: .random(in: 0 ... 1, using: &generator),
                        blue: .random(in: 0 ... 1, using: &generator),
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
    }

    private static func renderer(
        width: Int,
        height: Int
    ) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
    }

    private enum Colour {
        case red
        case white
        case other
    }

    /// The colour at a fraction of the way across and down the image, read
    /// off the bitmap so the assertion is about pixels and not about a view.
    private static func colour(
        of image: UIImage,
        atX x: CGFloat,
        y: CGFloat
    ) -> Colour {
        guard let bitmap = image.cgImage else { return .other }
        let width = bitmap.width
        let height = bitmap.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return .other }
        context.draw(
            bitmap,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let column = min(width - 1, max(0, Int(x * CGFloat(width))))
        let row = min(height - 1, max(0, Int(y * CGFloat(height))))
        let offset = (row * width + column) * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        if red > 200, green < 80, blue < 80 { return .red }
        if red > 200, green > 200, blue > 200 { return .white }
        return .other
    }
}
