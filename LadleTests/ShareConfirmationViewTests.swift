import SwiftUI
import XCTest

@MainActor
final class ShareConfirmationViewTests: XCTestCase {
    func testSuccessConfirmationRendersAtShareSheetSize() throws {
        let content = ShareConfirmationView(
            state: .success(sourceName: "instagram.com"),
            close: {}
        )
        .frame(width: 402, height: 620)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)

        XCTAssertEqual(image.size.width, 402)
        XCTAssertEqual(image.size.height, 620)

        let attachment = XCTAttachment(image: image)
        attachment.name = "Share confirmation — success"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
