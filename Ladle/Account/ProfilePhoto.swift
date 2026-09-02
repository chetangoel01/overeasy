import UIKit

/// A picture from the camera or the library, made into something an avatar
/// can be.
///
/// Everything happens on the device, before anything is sent: a 12-megapixel
/// HEIC from a modern iPhone is several megabytes and 4032 points wide, and
/// none of that survives being drawn into a 96-point circle. What the server
/// stores is 512 points square — enough for the circle at 3× on any display
/// Overeasy runs on — as a JPEG under half a mebibyte.
///
/// The crop is the centre square, with no interactive step in front of it.
/// A Contacts-style crop can follow if it is missed; a first version that
/// refuses to accept a photo until the cook has framed it is worse than one
/// that takes the middle, which is where a face in a portrait already is.
///
/// Pure, and free of SwiftUI, so the geometry is a unit test rather than a
/// screenshot.
enum ProfilePhoto {
    /// The stored side, in pixels. Not points: this is an image, and the
    /// renderer below is pinned to a scale of 1 so the number means the same
    /// thing on every device.
    static let side: CGFloat = 512

    /// What `PUT /v1/auth/avatar` accepts, and what it accepts it as.
    static let maximumBytes = 512 * 1024
    static let contentType = "image/jpeg"

    /// Tried in order until one fits. The first is what an ordinary photo
    /// lands on — a 512-square JPEG of a face is tens of kilobytes at 0.85 —
    /// and the rest are for the pictures that are all detail: noise, fabric,
    /// a screenshot of text.
    static let qualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4, 0.25]

    /// The centre square of `image`, drawn at `side` × `side`.
    ///
    /// Aspect-fill rather than a crop of the backing `CGImage`: drawing
    /// applies the image's EXIF orientation, and a bitmap crop does not — a
    /// photo taken in portrait would otherwise be squared along the wrong
    /// axis and come out rotated.
    static func square(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        // Left at the screen's scale this renders 1024 pixels on a 2×
        // device and 1536 on a 3×, which is four to nine times the bytes for
        // a picture nothing draws larger than 96 points.
        format.scale = 1
        format.opaque = true
        let bounds = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: bounds, format: format).image { _ in
            let source = image.size
            guard source.width > 0, source.height > 0 else { return }
            let fill = max(side / source.width, side / source.height)
            let drawn = CGSize(
                width: source.width * fill,
                height: source.height * fill
            )
            image.draw(
                in: CGRect(
                    x: (side - drawn.width) / 2,
                    y: (side - drawn.height) / 2,
                    width: drawn.width,
                    height: drawn.height
                )
            )
        }
    }

    /// The bytes to upload, or nil if even the lowest quality will not fit.
    ///
    /// Nil is close to impossible for a 512-square JPEG and is still a real
    /// answer rather than an oversized upload the server would refuse: the
    /// cook is told the photo did not save, which is true.
    static func jpeg(
        from image: UIImage,
        maximumBytes: Int = maximumBytes
    ) -> Data? {
        let cropped = square(image)
        for quality in qualities {
            guard let data = cropped.jpegData(compressionQuality: quality) else {
                return nil
            }
            if data.count <= maximumBytes {
                return data
            }
        }
        return nil
    }
}
