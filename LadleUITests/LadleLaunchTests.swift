import XCTest

@MainActor
final class LadleLaunchTests: XCTestCase {
    func testLaunchShowsRecipeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-onboarding-complete"]
        app.launch()

        XCTAssertTrue(
            app.otherElements["library.root"].waitForExistence(timeout: 2),
            "The recipe library root should be visible after launch."
        )
    }
}
