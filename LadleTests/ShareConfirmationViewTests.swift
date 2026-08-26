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

    func testRenderWindowCompletesAppearanceBeforeTeardown() throws {
        let window = try makeRenderWindow(
            size: CGSize(width: 402, height: 620)
        )
        let host = AppearanceTrackingViewController()
        attachRenderHost(host, to: window)

        XCTAssertEqual(host.willAppearCount, 1)
        XCTAssertEqual(host.didAppearCount, 1)

        tearDownRenderWindow(window)

        XCTAssertNil(window.rootViewController)
        XCTAssertEqual(host.willDisappearCount, 1)
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
        attachRenderHost(host, to: window)
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
        window.isHidden = true
        flushAppearanceUpdates()
        window.rootViewController = nil
    }

    private func attachRenderHost(
        _ host: UIViewController,
        to window: UIWindow
    ) {
        window.rootViewController = host
        window.isHidden = false
        flushAppearanceUpdates()
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

    private func flushAppearanceUpdates() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
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

@MainActor
private final class AppearanceTrackingViewController: UIViewController {
    private(set) var willAppearCount = 0
    private(set) var didAppearCount = 0
    private(set) var willDisappearCount = 0

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        willAppearCount += 1
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppearCount += 1
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        willDisappearCount += 1
    }
}
