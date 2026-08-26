import SwiftUI
import UIKit
import XCTest

@MainActor
final class ShareConfirmationViewTests: XCTestCase {
    func testConfirmationUsesCurrentProductBrand() {
        XCTAssertEqual(ShareConfirmationView.brandName, "Overeasy")
    }

    func testOnlyCompletedStatesOfferExplicitDoneAction() {
        XCTAssertNil(
            ShareConfirmationView.dismissalTitle(for: .loading)
        )
        XCTAssertEqual(
            ShareConfirmationView.dismissalTitle(
                for: .success(sourceName: "instagram.com")
            ),
            "Done"
        )
        XCTAssertEqual(
            ShareConfirmationView.dismissalTitle(
                for: .failure(message: "Try again.")
            ),
            "Done"
        )
    }

    func testSuccessConfirmationRendersAtShareSheetSize() throws {
        try assertRenders(
            state: .success(sourceName: "instagram.com"),
            attachmentName: "Share confirmation — success"
        )
    }

    func testSuccessConfirmationRendersInDarkMode() throws {
        try assertRenders(
            state: .success(sourceName: "youtube.com"),
            colorScheme: .dark,
            attachmentName: "Share confirmation — success, dark"
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

    func testRenderWindowDetachesItsHostDuringTeardown() throws {
        let window = try makeRenderWindow(
            size: CGSize(width: 402, height: 620)
        )
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()

        tearDownRenderWindow(window)

        XCTAssertNil(window.rootViewController)
    }

    private func assertRenders(
        state: ShareConfirmationState,
        dynamicTypeSize: DynamicTypeSize = .large,
        colorScheme: ColorScheme = .light,
        attachmentName: String
    ) throws {
        let content = ShareConfirmationView(state: state, close: {})
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.colorScheme, colorScheme)
            .frame(width: 402, height: 620)
        let size = CGSize(width: 402, height: 620)
        let host = UIHostingController(rootView: content)
        let window = try makeRenderWindow(size: size)
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
        tearDownRenderWindow(window)

        XCTAssertTrue(didDraw)
        XCTAssertEqual(image.size.width, 402)
        XCTAssertEqual(image.size.height, 620)
        XCTAssertGreaterThan(sampledColorCount(in: image), 8)

        let attachment = XCTAttachment(image: image)
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tearDownRenderWindow(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
    }

    private func makeRenderWindow(size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        return window
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
