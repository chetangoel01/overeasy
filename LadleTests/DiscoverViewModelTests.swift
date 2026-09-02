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

    func testLoadOmitsRecipesAlreadySavedByTheCurrentCook() async {
        let unsaved = discoveredRecipe()
        let saved = discoveredRecipe(
            sourceID: UUID(
                uuidString: "90000000-0000-4000-8000-000000000002"
            )!,
            savedRecipeID: UUID()
        )
        let viewModel = DiscoverViewModel(
            service: DiscoverTestService(
                result: .success([saved, unsaved])
            )
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded([unsaved]))
    }

    /// The demo feed rendered placeholder pans because fixture artwork is a
    /// bundled asset with no remote URL, and demo builds run without a
    /// RemoteImageCache — so only the local-asset path can ever draw.
    func testDemoDiscoverRowsResolveBundledArtwork() async throws {
        let service = DemoDiscoverService()

        let page = try await service.fetchDiscoverPage(
            cursor: 0,
            query: "",
            sort: .popular
        )

        XCTAssertFalse(page.recipes.isEmpty)
        for recipe in page.recipes {
            XCTAssertNotNil(
                PreviewFixtures.discoverArtwork(sourceID: recipe.sourceID),
                "\(recipe.title) resolves no artwork, so its row is a placeholder"
            )
        }
    }

    // MARK: - Shelves

    func testLoadFillsBothShelvesBesideTheFirstPage() async {
        let service = DiscoverTestService(
            result: .success((1...4).map { paged($0) })
        )
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(
            viewModel.visibleShelves.map(\.id),
            [.newToOvereasy, .quickDinners]
        )
        XCTAssertEqual(viewModel.visibleShelves.first?.title, "New to Overeasy")
        XCTAssertEqual(viewModel.visibleShelves.last?.title, "Quick dinners")
        // Two shelf fetches on top of the feed's own page, and each one is
        // the feed under a different order or filter rather than a new call.
        XCTAssertEqual(viewModel.state, .loaded((1...4).map { paged($0) }))
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(
            Set(service.shelfRequests.map(\.sort)),
            [.newest, .popular]
        )
        XCTAssertEqual(
            service.shelfRequests.first(where: { $0.sort == .newest })?
                .maxTotalMinutes,
            nil
        )
        XCTAssertEqual(
            service.shelfRequests.first(where: { $0.sort == .popular })?
                .maxTotalMinutes,
            30
        )
        // A rail has no cursor of its own: it asks for one short page and
        // never pages, because there is no "See all" to page towards.
        XCTAssertTrue(service.shelfRequests.allSatisfy { $0.cursor == 0 })
        XCTAssertTrue(service.shelfRequests.allSatisfy { $0.query.isEmpty })
        XCTAssertTrue(
            service.shelfRequests.allSatisfy {
                $0.limit == DiscoverPaging.shelfSize
            }
        )
    }

    func testAFailedShelfHidesItsRailAndLeavesTheFeedAlone() async {
        let recipes = (1...4).map { paged($0) }
        let service = DiscoverTestService(result: .success(recipes))
        service.shelfResult = .failure(TestError.failed)
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()

        XCTAssertTrue(viewModel.visibleShelves.isEmpty)
        XCTAssertEqual(viewModel.state, .loaded(recipes))
        XCTAssertEqual(viewModel.refreshState, .current)
    }

    /// The other direction: the rails are worth showing even when the page
    /// beneath them did not arrive, so a feed failure must not clear them.
    func testAFailedFeedStillFillsTheShelves() async {
        let service = DiscoverTestService(result: .failure(TestError.failed))
        service.shelfResult = .success((1...4).map { paged($0) })
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.visibleShelves.count, 2)
        guard case .failed = viewModel.state else {
            return XCTFail("Expected the feed itself to report the failure")
        }
    }

    func testARailWithFewerThanThreeCardsIsHidden() async {
        let service = DiscoverTestService(
            result: .success((1...4).map { paged($0) })
        )
        service.shelfResult = .success([paged(1), paged(2)])
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.shelves.count, 2, "Both rails still loaded")
        XCTAssertTrue(viewModel.visibleShelves.isEmpty)
    }

    func testSearchHidesTheRailsAndAsksForNoShelves() async {
        let service = DiscoverTestService(
            result: .success((1...4).map { paged($0) })
        )
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        XCTAssertFalse(viewModel.visibleShelves.isEmpty)

        // Typing hides the rails immediately, before the debounced reload
        // that will empty them has even been scheduled.
        viewModel.query = "lemon"
        XCTAssertTrue(viewModel.visibleShelves.isEmpty)

        let shelfRequestsBefore = service.shelfRequests.count
        await viewModel.load()

        XCTAssertTrue(viewModel.visibleShelves.isEmpty)
        XCTAssertEqual(
            service.shelfRequests.count,
            shelfRequestsBefore,
            "A search must not spend two requests on rails it will not draw"
        )
    }

    /// Watch builds its own view model for the same feed and has nowhere to
    /// draw a rail, so it must not pay for one.
    func testAViewModelThatDrawsNoShelvesFetchesNone() async {
        let service = DiscoverTestService(
            result: .success((1...4).map { paged($0) })
        )
        let viewModel = DiscoverViewModel(service: service, loadsShelves: false)

        await viewModel.load()

        XCTAssertTrue(viewModel.shelves.isEmpty)
        XCTAssertTrue(viewModel.visibleShelves.isEmpty)
        XCTAssertTrue(service.shelfRequests.isEmpty)
        XCTAssertEqual(service.requests.count, 1)
    }

    func testSavingFromARailRemovesTheCardFromIt() async {
        let recipes = (1...4).map { paged($0) }
        let service = DiscoverTestService(
            result: .success(recipes),
            savedResult: .success(
                SavedDiscoverRecipe(recipe: PreviewFixtures.recipes[0], revision: 1)
            )
        )
        let viewModel = DiscoverViewModel(service: service)
        await viewModel.load()

        _ = await viewModel.save(recipes[0])

        XCTAssertTrue(
            viewModel.shelves.allSatisfy { shelf in
                !shelf.recipes.contains(recipes[0])
            }
        )
        // Three of four left, so the rails survive the save rather than
        // dropping under the minimum.
        XCTAssertEqual(viewModel.visibleShelves.count, 2)
    }

    // MARK: - Seen sources

    /// The whole point of the pin. `seenBefore` is the moment the walk
    /// started, so the impressions each page writes are newer than it and
    /// cannot re-rank the pages still to come; a fresh timestamp per page
    /// would demote what page 1 served and hand page 2 repeats.
    func testLoadMoreReusesTheTimestampTheSessionStartedWith() async {
        let service = DiscoverTestService(result: .success((1...5).map { paged($0) }))
        service.pageSize = 2
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        await viewModel.loadMore()
        await viewModel.loadMore()

        let stamps = service.requests.map(\.seenBefore)
        XCTAssertEqual(stamps.count, 3)
        XCTAssertNotNil(stamps.first ?? nil)
        XCTAssertEqual(Set(stamps.map { $0?.timeIntervalSinceReferenceDate }).count, 1)
    }

    /// Pull to refresh, a new sort, or coming back to a feed already read.
    /// Each is the cook asking for a different list, which is exactly when
    /// the previous session's rows should sink.
    func testLoadRenewsTheSessionTimestamp() async {
        let service = DiscoverTestService(result: .success((1...5).map { paged($0) }))
        service.pageSize = 2
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        await viewModel.loadMore()
        let firstSession = service.requests.first?.seenBefore
        await viewModel.load()

        XCTAssertNotNil(firstSession)
        XCTAssertNotNil(service.requests.last?.seenBefore)
        XCTAssertNotEqual(service.requests.last?.seenBefore, firstSession)
    }

    /// A rail is a ranking, not a reading position. "New to Overeasy" that
    /// hid what is new because the cook glanced at it would stop meaning what
    /// its title says.
    func testShelvesNeitherReportNorPinSeenSources() async {
        let service = DiscoverTestService(
            result: .success((1...4).map { paged($0) })
        )
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(service.shelfRequests.count, 2)
        XCTAssertTrue(service.shelfRequests.allSatisfy { $0.seenBefore == nil })
    }

    /// Watch shares this view model but is a different surface: a video
    /// swiped past there is not a row read in the list, and its feed has to
    /// stay the same on every launch for the UI tests to mean anything.
    func testWatchSendsNoSessionTimestamp() async {
        let service = DiscoverTestService(result: .success((1...5).map { paged($0) }))
        service.pageSize = 2
        let viewModel = DiscoverViewModel(
            service: service,
            removesSavedRecipeImmediately: false,
            loadsShelves: false,
            recordsSeenSources: false
        )

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(service.requests.count, 2)
        XCTAssertTrue(service.requests.allSatisfy { $0.seenBefore == nil })
        XCTAssertTrue(service.shelfRequests.isEmpty)
    }

    // MARK: - Paging

    func testLoadMoreAppendsTheNextPage() async {
        let all = (1...5).map { paged($0) }
        let service = DiscoverTestService(result: .success(all))
        service.pageSize = 2
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(Array(all.prefix(2))))
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.state, .loaded(Array(all.prefix(4))))

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.state, .loaded(all))
        XCTAssertFalse(viewModel.hasMore)

        // Nothing left: loadMore is a no-op rather than refetching the tail.
        let requestCount = service.requests.count
        await viewModel.loadMore()
        XCTAssertEqual(service.requests.count, requestCount)
    }

    func testLoadMoreAdvancesTheCursorRatherThanRefetchingPageOne() async {
        let service = DiscoverTestService(
            result: .success((1...4).map { paged($0) })
        )
        service.pageSize = 2
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(service.requests.map(\.cursor), [0, 2])
    }

    func testLoadMoreDropsRecipesAlreadyOnScreen() async {
        // A save between pages shifts the server's window, so the same source
        // can arrive twice. It must not render twice.
        let all = (1...4).map { paged($0) }
        let service = DiscoverTestService(result: .success(all))
        service.pageSize = 3
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        service.overrideNextPage = [all[2], all[3]]
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.state, .loaded(all))
    }

    func testSearchRestartsPagingAndAsksTheServer() async {
        let service = DiscoverTestService(
            result: .success((1...4).map { paged($0) })
        )
        service.pageSize = 2
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        await viewModel.loadMore()
        viewModel.query = "lemon"
        await viewModel.load()

        XCTAssertEqual(service.requests.map(\.cursor), [0, 2, 0])
        XCTAssertEqual(service.requests.last?.query, "lemon")
    }

    func testSortChangeAsksTheServerForTheWholeOrder() async {
        let service = DiscoverTestService(
            result: .success((1...3).map { paged($0) })
        )
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        viewModel.sort = .alphabetical
        await viewModel.load()

        XCTAssertEqual(service.requests.last?.sort, .alphabetical)
        XCTAssertEqual(service.requests.last?.cursor, 0)
    }

    func testLoadMoreFailureKeepsWhatIsAlreadyOnScreen() async {
        let all = (1...4).map { paged($0) }
        let service = DiscoverTestService(result: .success(all))
        service.pageSize = 2
        let viewModel = DiscoverViewModel(service: service)

        await viewModel.load()
        service.result = .failure(TestError.failed)
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.state, .loaded(Array(all.prefix(2))))
        XCTAssertFalse(viewModel.hasMore)
    }

    func testInitialLoadClassifiesRemoteFailures() async throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let rateLimit = try remoteError(
            code: .rateLimited,
            details: "\"retryAt\":\"2027-01-15T08:00:00.000Z\""
        )
        let provider = try remoteError(code: .providerUnavailable)
        let cases: [(APIError, RemoteFailure)] = [
            (.transport, .offline),
            (.remote(rateLimit), .rateLimited(retryAt: retryAt)),
            (.remote(provider), .serviceUnavailable),
        ]

        for (error, expected) in cases {
            let viewModel = DiscoverViewModel(
                service: DiscoverTestService(result: .failure(error))
            )

            await viewModel.load()

            guard case let .failed(report) = viewModel.state else {
                return XCTFail("Expected classified first-load failure")
            }
            XCTAssertEqual(report.failure, expected)
        }
    }

    func testRefreshKeepsContentThenExposesStaleFailureAndRecovers() async {
        let recipe = discoveredRecipe()
        let service = DiscoverTestService(result: .success([recipe]))
        let viewModel = DiscoverViewModel(service: service)
        await viewModel.load()

        service.result = .failure(APIError.transport)
        service.pausesFetch = true
        let refresh = Task { await viewModel.load() }
        while !service.fetchIsSuspended { await Task.yield() }

        XCTAssertEqual(viewModel.state, .loaded([recipe]))
        XCTAssertEqual(viewModel.refreshState, .refreshing)

        service.resumeFetch()
        await refresh.value

        XCTAssertEqual(viewModel.state, .loaded([recipe]))
        XCTAssertEqual(
            viewModel.refreshState,
            .failed(RemoteFailureReport(APIError.transport))
        )

        let replacement = discoveredRecipe(
            sourceID: UUID(
                uuidString: "90000000-0000-4000-8000-000000000009"
            )!
        )
        service.result = .success([replacement])
        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded([replacement]))
        XCTAssertEqual(viewModel.refreshState, .current)
    }

    func testInitialLoadOffersRetryWhenDiscoveryFails() async {
        let viewModel = DiscoverViewModel(
            service: DiscoverTestService(result: .failure(APIError.transport))
        )

        await viewModel.load()

        XCTAssertEqual(
            viewModel.state,
            .failed(RemoteFailureReport(APIError.transport))
        )
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

        await viewModel.load()
        let result = await viewModel.save(recipe)

        XCTAssertEqual(result, saved)
        XCTAssertTrue(viewModel.isSaved(recipe))
        XCTAssertEqual(viewModel.state, .loaded([]))
        XCTAssertEqual(service.savedSourceIDs, [recipe.sourceID])
    }

    func testWatchSaveKeepsCurrentSessionVisibleUntilReload() async {
        let recipe = discoveredRecipe()
        let saved = SavedDiscoverRecipe(
            recipe: PreviewFixtures.recipes[0],
            revision: 3
        )
        let viewModel = DiscoverViewModel(
            service: DiscoverTestService(
                result: .success([recipe]),
                savedResult: .success(saved)
            ),
            removesSavedRecipeImmediately: false
        )

        await viewModel.load()
        _ = await viewModel.save(recipe)

        XCTAssertEqual(viewModel.state, .loaded([recipe]))
        XCTAssertTrue(viewModel.isSaved(recipe))
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

    func testOpenAndSaveExposeIndependentProgress() async {
        let recipe = discoveredRecipe()
        let saved = SavedDiscoverRecipe(
            recipe: PreviewFixtures.recipes[0],
            revision: 3
        )
        let service = DiscoverTestService(
            result: .success([recipe]),
            savedResult: .success(saved),
            detailResult: .success(PreviewFixtures.recipes[0])
        )
        service.pausesDetail = true
        service.pausesSave = true
        let viewModel = DiscoverViewModel(service: service)

        let open = Task { await viewModel.detail(for: recipe) }
        while !service.detailIsSuspended { await Task.yield() }
        XCTAssertTrue(viewModel.isLoadingDetail(recipe))
        XCTAssertFalse(viewModel.isSaving(recipe))

        let save = Task { await viewModel.save(recipe) }
        while !service.saveIsSuspended { await Task.yield() }
        XCTAssertTrue(viewModel.isLoadingDetail(recipe))
        XCTAssertTrue(viewModel.isSaving(recipe))

        service.resumeDetail()
        _ = await open.value
        XCTAssertFalse(viewModel.isLoadingDetail(recipe))
        XCTAssertTrue(viewModel.isSaving(recipe))

        service.resumeSave()
        _ = await save.value
        XCTAssertFalse(viewModel.isSaving(recipe))
    }

    func testOpenAndSaveKeepIndependentClassifiedFailures() async throws {
        let recipe = discoveredRecipe()
        let provider = try remoteError(code: .providerUnavailable)
        let service = DiscoverTestService(
            result: .success([recipe]),
            savedResult: .failure(APIError.remote(provider)),
            detailResult: .failure(APIError.transport)
        )
        let viewModel = DiscoverViewModel(service: service)

        _ = await viewModel.detail(for: recipe)
        _ = await viewModel.save(recipe)

        XCTAssertEqual(
            viewModel.detailFailure(for: recipe)?.failure,
            .offline
        )
        XCTAssertEqual(
            viewModel.saveFailure(for: recipe)?.failure,
            .serviceUnavailable
        )

        service.detailResult = .success(PreviewFixtures.recipes[0])
        _ = await viewModel.detail(for: recipe)

        XCTAssertNil(viewModel.detailFailure(for: recipe))
        XCTAssertEqual(
            viewModel.saveFailure(for: recipe)?.failure,
            .serviceUnavailable
        )
    }
}

private final class DiscoverTestService: DiscoverServing {
    var result: Result<[DiscoverRecipe], any Error>
    var savedResult: Result<SavedDiscoverRecipe, any Error>
    var detailResult: Result<Recipe, any Error>
    var pausesFetch = false
    var pausesSave = false
    var pausesDetail = false
    private(set) var fetchIsSuspended = false
    private(set) var saveIsSuspended = false
    private(set) var detailIsSuspended = false
    private(set) var savedSourceIDs: [UUID] = []
    private(set) var detailSourceIDs: [UUID] = []
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var detailContinuation: CheckedContinuation<Void, Never>?

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

    struct FetchRequest: Equatable {
        let cursor: Int
        let query: String
        let sort: DiscoverSort
        var maxTotalMinutes: Int?
        var limit: Int = DiscoverPaging.pageSize
        var seenBefore: Date?

        /// A shelf asks for a short page; the feed asks for a full one. That
        /// is the only thing that tells the two apart on the wire.
        var isShelf: Bool { limit == DiscoverPaging.shelfSize }
    }

    /// Feed pages only. Shelf fetches are recorded separately so that every
    /// assertion about the feed's cursor walk still means what it did before
    /// the rails existed.
    private(set) var requests: [FetchRequest] = []
    private(set) var shelfRequests: [FetchRequest] = []
    /// Forces the next page's contents, to simulate the server's window
    /// shifting between requests.
    var overrideNextPage: [DiscoverRecipe]?
    /// One page by default, so tests that predate paging keep their meaning.
    var pageSize: Int?
    /// What the shelf fetches return, when they should not simply mirror the
    /// feed — including a failure, which must not reach the feed.
    var shelfResult: Result<[DiscoverRecipe], any Error>?

    func fetchDiscoverPage(
        cursor: Int,
        query: String,
        sort: DiscoverSort,
        maxTotalMinutes: Int?,
        limit: Int,
        seenBefore: Date?
    ) async throws -> DiscoverPage {
        let request = FetchRequest(
            cursor: cursor,
            query: query,
            sort: sort,
            maxTotalMinutes: maxTotalMinutes,
            limit: limit,
            seenBefore: seenBefore
        )
        if request.isShelf {
            shelfRequests.append(request)
            // Shelf fetches never take the pause or the paging overrides:
            // those belong to the feed, and one shared continuation cannot
            // serve three concurrent requests.
            let recipes = try (shelfResult ?? result).get()
            return DiscoverPage(
                recipes: recipes,
                nextCursor: recipes.count,
                hasMore: false
            )
        }
        requests.append(request)
        if pausesFetch {
            fetchIsSuspended = true
            await withCheckedContinuation { fetchContinuation = $0 }
            fetchIsSuspended = false
            pausesFetch = false
        }
        let all = try result.get()
        if let overrideNextPage {
            self.overrideNextPage = nil
            return DiscoverPage(
                recipes: overrideNextPage,
                nextCursor: cursor + overrideNextPage.count,
                hasMore: false
            )
        }
        let start = min(cursor, all.count)
        let end = pageSize.map { min(start + $0, all.count) } ?? all.count
        return DiscoverPage(
            recipes: Array(all[start..<end]),
            nextCursor: end,
            hasMore: end < all.count
        )
    }

    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe {
        savedSourceIDs.append(sourceID)
        if pausesSave {
            saveIsSuspended = true
            await withCheckedContinuation { saveContinuation = $0 }
            saveIsSuspended = false
            pausesSave = false
        }
        return try savedResult.get()
    }

    func fetchDiscoverRecipe(sourceID: UUID) async throws -> Recipe {
        detailSourceIDs.append(sourceID)
        if pausesDetail {
            detailIsSuspended = true
            await withCheckedContinuation { detailContinuation = $0 }
            detailIsSuspended = false
            pausesDetail = false
        }
        return try detailResult.get()
    }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func resumeDetail() {
        detailContinuation?.resume()
        detailContinuation = nil
    }
}

private enum TestError: Error {
    case failed
}

private func discoveredRecipe(
    sourceID: UUID = UUID(
        uuidString: "90000000-0000-4000-8000-000000000001"
    )!,
    savedRecipeID: UUID? = nil
) -> DiscoverRecipe {
    DiscoverRecipe(
        sourceID: sourceID,
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

private func paged(_ index: Int) -> DiscoverRecipe {
    discoveredRecipe(
        sourceID: UUID(
            uuidString: "90000000-0000-4000-8000-00000000000\(index)"
        )!
    )
}

private func remoteError(
    code: RemoteErrorCode,
    details: String? = nil
) throws -> RemoteErrorDTO {
    let detailsJSON = details.map { ",\"details\":{\($0)}" } ?? ""
    let json = """
    {
      "error": {
        "code": "\(code.rawValue)",
        "message": "server detail",
        "retryable": true,
        "requestID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"\(detailsJSON)
      }
    }
    """
    return try RemoteContractJSON.decoder()
        .decode(RemoteErrorEnvelope.self, from: Data(json.utf8))
        .error
}
