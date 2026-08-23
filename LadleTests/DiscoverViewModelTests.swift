import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    func testLoadPublishesDiscoveredRecipes() async {
        let recipe = DiscoverRecipe(
            title: "Lemon Orzo",
            description: "Creamy lemon orzo with spinach.",
            creatorName: "@mia_cooks",
            source: .tiktok,
            originalURL: URL(
                string: "https://www.tiktok.com/@mia_cooks/video/1234567890"
            )!,
            imageURL: nil,
            savedCount: 12
        )
        let viewModel = DiscoverViewModel(
            service: DiscoverTestService(result: .success([recipe]))
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded([recipe]))
    }

    func testLoadOffersRetryWhenDiscoveryFails() async {
        let viewModel = DiscoverViewModel(
            service: DiscoverTestService(result: .failure(TestError.failed))
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .failed)
    }
}

private struct DiscoverTestService: DiscoverServing {
    let result: Result<[DiscoverRecipe], any Error>

    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        try result.get()
    }
}

private enum TestError: Error {
    case failed
}
