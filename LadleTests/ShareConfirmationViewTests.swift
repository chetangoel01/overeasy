import SwiftUI
import UIKit
import XCTest

@MainActor
final class ShareConfirmationViewTests: XCTestCase {
    func testConfirmationUsesCurrentProductBrand() {
        XCTAssertEqual(ShareConfirmationView.brandName, "Overeasy")
    }

    func testSuccessConfirmationRendersAtShareSheetSize() throws {
        try assertRenders(
            state: .success(sourceName: "instagram.com"),
            attachmentName: "Share confirmation — success"
        )
    }

    func testLoadingConfirmationRendersAtAccessibilitySize() throws {
        try assertRenders(
            state: .loading,
            dynamicTypeSize: .accessibility3,
            attachmentName: "Share confirmation — loading, accessibility"
        )
    }

    func testFailureConfirmationRendersAtAccessibilitySize() throws {
        try assertRenders(
            state: .failure(message: "Please try that link again."),
            dynamicTypeSize: .accessibility3,
            attachmentName: "Share confirmation — failure, accessibility"
        )
    }

    private func assertRenders(
        state: ShareConfirmationState,
        dynamicTypeSize: DynamicTypeSize = .large,
        attachmentName: String
    ) throws {
        let content = ShareConfirmationView(state: state, close: {})
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .frame(width: 402, height: 620)
        let size = CGSize(width: 402, height: 620)
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        var didDraw = false
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            didDraw = host.view.drawHierarchy(
                in: host.view.bounds,
                afterScreenUpdates: true
            )
        }
        window.isHidden = true

        XCTAssertTrue(didDraw)
        XCTAssertEqual(image.size.width, 402)
        XCTAssertEqual(image.size.height, 620)
        XCTAssertGreaterThan(sampledColorCount(in: image), 8)

        let attachment = XCTAttachment(image: image)
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sampledColorCount(in image: UIImage) -> Int {
        guard
            let cgImage = image.cgImage,
            let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            return 0
        }
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 1)
        var colors: Set<UInt64> = []
        let xStep = max(cgImage.width / 32, 1)
        let yStep = max(cgImage.height / 32, 1)

        for y in stride(from: 0, to: cgImage.height, by: yStep) {
            for x in stride(from: 0, to: cgImage.width, by: xStep) {
                let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
                var value: UInt64 = 0
                for byte in 0..<min(bytesPerPixel, 8) {
                    value = (value << 8) | UInt64(bytes[offset + byte])
                }
                colors.insert(value)
            }
        }
        return colors.count
    }
}
