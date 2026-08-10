import UniformTypeIdentifiers
import XCTest
@testable import Ladle

@MainActor
final class ShareURLExtractorTests: XCTestCase {
    func testExtractsDirectHTTPURLProvider() async {
        let expected = URL(
            string: "https://www.instagram.com/reel/lemon-orzo"
        )!
        let provider = NSItemProvider(object: expected as NSURL)

        let extracted = await ShareURLExtractor()
            .firstSupportedURL(in: [extensionItem(provider)])

        XCTAssertEqual(extracted, expected)
    }

    func testExtractsURLFromPlainTextProvider() async {
        let provider = NSItemProvider(
            object:
                "Try this tonight: https://youtu.be/green-curry?t=22"
                    as NSString
        )

        let extracted = await ShareURLExtractor()
            .firstSupportedURL(in: [extensionItem(provider)])

        XCTAssertEqual(
            extracted,
            URL(string: "https://youtu.be/green-curry?t=22")
        )
    }

    func testExtractsURLFromItemAttributedContentText() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(
            string:
                "Try this recipe: https://www.instagram.com/share/reel/C9_recipe-ID/"
        )

        let extracted = await ShareURLExtractor()
            .firstSupportedURL(in: [item])

        XCTAssertEqual(
            extracted,
            URL(
                string:
                    "https://www.instagram.com/share/reel/C9_recipe-ID/"
            )
        )
    }

    func testSearchesMultipleAttachmentsForFirstSupportedURL() async {
        let unsupported = NSItemProvider(
            item: Data([0x01]) as NSSecureCoding,
            typeIdentifier: UTType.data.identifier
        )
        let expected = URL(
            string: "https://www.tiktok.com/@cook/video/123"
        )!
        let supported = NSItemProvider(object: expected as NSURL)
        let emptyText = NSItemProvider(
            object: "No link here" as NSString
        )

        let extracted = await ShareURLExtractor()
            .firstSupportedURL(
                in: [
                    extensionItem(unsupported, emptyText),
                    extensionItem(supported),
                ]
            )

        XCTAssertEqual(extracted, expected)
    }

    func testRejectsUnsupportedSchemes() async {
        let provider = NSItemProvider(
            object: URL(
                string: "ftp://recipes.example.com/soup"
            )! as NSURL
        )

        let extracted = await ShareURLExtractor()
            .firstSupportedURL(in: [extensionItem(provider)])

        XCTAssertNil(extracted)
    }

    func testReturnsNilWhenAttachmentsContainNoURL() async {
        let provider = NSItemProvider(
            object: "Grandma’s handwritten soup" as NSString
        )

        let extracted = await ShareURLExtractor()
            .firstSupportedURL(in: [extensionItem(provider)])

        XCTAssertNil(extracted)
    }

    private func extensionItem(
        _ providers: NSItemProvider...
    ) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        return item
    }
}
