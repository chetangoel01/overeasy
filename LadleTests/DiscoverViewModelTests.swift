import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    func testLoadPublishesDiscoveredRecipes() async {
        let recipe = discoveredRecipe()
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

    func testSaveClonesLoadedRecipeWithoutSubmittingAnImport() async {
        let recipe = discoveredRecipe()
        let saved = SavedDiscoverRecipe(
            recipe: PreviewFixtures.recipes[0],
            revision: 3
        )
        let service = DiscoverTestService(
            result: .success([recipe]),
            savedResult: .success(saved)
        )
        let viewModel = DiscoverViewModel(service: service)

        let result = await viewModel.save(recipe)

        XCTAssertEqual(result, saved)
        XCTAssertTrue(viewModel.isSaved(recipe))
        XCTAssertEqual(service.savedSourceIDs, [recipe.sourceID])
    }

    func testSaveIsIdempotentWhileRecipeIsMarkedSaved() async {
        let recipe = discoveredRecipe(savedRecipeID: UUID())
        let service = DiscoverTestService(result: .success([recipe]))
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        let result = await viewModel.save(recipe)

        XCTAssertNil(result)
        XCTAssertTrue(viewModel.isSaved(recipe))
        XCTAssertTrue(service.savedSourceIDs.isEmpty)
    }

    func testOpeningRecipeLoadsFullDiscoverDetail() async {
        let recipe = discoveredRecipe()
        let detail = PreviewFixtures.recipes[0]
        let service = DiscoverTestService(
            result: .success([recipe]),
            detailResult: .success(detail)
        )
        let viewModel = DiscoverViewModel(service: service)

        let result = await viewModel.detail(for: recipe)

        XCTAssertEqual(result, detail)
        XCTAssertEqual(service.detailSourceIDs, [recipe.sourceID])
        XCTAssertFalse(viewModel.isLoadingDetail(recipe))
    }
}

private final class DiscoverTestService: DiscoverServing {
    let result: Result<[DiscoverRecipe], any Error>
    let savedResult: Result<SavedDiscoverRecipe, any Error>
    let detailResult: Result<Recipe, any Error>
    private(set) var savedSourceIDs: [UUID] = []
    private(set) var detailSourceIDs: [UUID] = []

    init(
        result: Result<[DiscoverRecipe], any Error>,
        savedResult: Result<SavedDiscoverRecipe, any Error> =
            .failure(TestError.failed),
        detailResult: Result<Recipe, any Error> = .failure(TestError.failed)
    ) {
        self.result = result
        self.savedResult = savedResult
        self.detailResult = detailResult
    }

    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        try result.get()
    }

    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe {
        savedSourceIDs.append(sourceID)
        return try savedResult.get()
    }

    func fetchDiscoverRecipe(sourceID: UUID) async throws -> Recipe {
        detailSourceIDs.append(sourceID)
        return try detailResult.get()
    }
}

private enum TestError: Error {
    case failed
}

private func discoveredRecipe(
    savedRecipeID: UUID? = nil
) -> DiscoverRecipe {
    DiscoverRecipe(
        sourceID: UUID(uuidString: "90000000-0000-4000-8000-000000000001")!,
        title: "Lemon Orzo",
        description: "Creamy lemon orzo with spinach.",
        creatorName: "@mia_cooks",
        source: .tiktok,
        originalURL: URL(
            string: "https://www.tiktok.com/@mia_cooks/video/1234567890"
        )!,
        imageURL: nil,
        savedCount: 12,
        savedRecipeID: savedRecipeID
    )
}
