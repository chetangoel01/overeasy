import Foundation
import LadleCore
import XCTest
@testable import Ladle

final class RemoteImageCacheTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testDownloadsOnceAndServesLocalFileAfterward() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestCount = Locked(0)
        URLProtocolStub.install { request in
            requestCount.withValue { $0 += 1 }
            return (
                Self.response(request),
                Data([0x89, 0x50, 0x4E, 0x47])
            )
        }
        let cache = makeCache(directory: directory)
        let image = RemoteRecipeImageDTO(
            id: UUID(),
            remoteURL: URL(
                string: "https://images.ladle.test/signed/first"
            )!
        )

        let first = try await cache.localURL(
            owner: .recipe(id: UUID()),
            image: image
        )
        let second = try await cache.localURL(
            owner: .recipe(id: UUID()),
            image: image
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(requestCount.snapshot, 1)
    }

    func testExpiredURLRefreshesRecipeAndRetriesImageOnlyOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recipeID = UUID(
            uuidString: "20000000-0000-4000-8000-000000000001"
        )!
        let imageID = UUID(
            uuidString: "21000000-0000-4000-8000-000000000001"
        )!
        let paths = Locked<[String]>([])
        URLProtocolStub.install { request in
            paths.withValue {
                $0.append(request.url?.absoluteString ?? "")
            }
            if request.url?.path == "/expired" {
                return (Self.response(request, status: 403), Data())
            }
            if request.url?.path == "/v1/recipes/\(recipeID.uuidString)" {
                return (
                    Self.response(request),
                    try! Self.refreshedRecipeFixture()
                )
            }
            return (
                Self.response(request),
                Data([0xFF, 0xD8, 0xFF])
            )
        }
        let cache = makeCache(directory: directory)

        let local = try await cache.localURL(
            owner: .recipe(id: recipeID),
            image: RemoteRecipeImageDTO(
                id: imageID,
                remoteURL: URL(
                    string: "https://images.ladle.test/expired"
                )!
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(paths.snapshot.count, 3)
        XCTAssertEqual(
            paths.snapshot.filter { $0.contains("/v1/recipes/") }.count,
            1
        )
        XCTAssertEqual(
            paths.snapshot.filter { $0.contains("/refreshed") }.count,
            1
        )
    }

    func testUnavailableImagePreservesHTTPStatus() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocolStub.install { request in
            (Self.response(request, status: 404), Data())
        }

        do {
            _ = try await makeCache(directory: directory).localURL(
                owner: .recipe(id: UUID()),
                image: RemoteRecipeImageDTO(
                    id: UUID(),
                    remoteURL: URL(
                        string: "https://images.ladle.test/missing"
                    )!
                )
            )
            XCTFail("Expected unavailable image")
        } catch {
            XCTAssertEqual(
                error as? RemoteImageCacheError,
                .unavailable(statusCode: 404)
            )
        }
    }

    func testRefreshFailsWhenRecipeNoLongerContainsImage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocolStub.install { request in
            if request.url?.host == "images.ladle.test" {
                return (Self.response(request, status: 403), Data())
            }
            return (
                Self.response(request),
                try! Self.refreshedRecipeFixture(includesImage: false)
            )
        }

        do {
            _ = try await makeCache(directory: directory).localURL(
                owner: .recipe(id: UUID()),
                image: RemoteRecipeImageDTO(
                    id: UUID(),
                    remoteURL: URL(
                        string: "https://images.ladle.test/expired"
                    )!
                )
            )
            XCTFail("Expected missing refreshed image")
        } catch {
            XCTAssertEqual(
                error as? RemoteImageCacheError,
                .refreshedImageMissing
            )
        }
    }

    func testExpiredDiscoverThumbnailRefreshesThroughTheDiscoverDetail()
        async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A Discover card passes the sourceID, which is not a recipe in
        // the caller's library, and mints its own image id from it — so
        // the refreshed thumbnail's server-minted id never matches.
        let sourceID = UUID(
            uuidString: "90000000-0000-4000-8000-000000000001"
        )!
        let paths = Locked<[String]>([])
        URLProtocolStub.install { request in
            paths.withValue {
                $0.append(request.url?.absoluteString ?? "")
            }
            if request.url?.path == "/expired" {
                return (Self.response(request, status: 403), Data())
            }
            if request.url?.path
                == "/v1/recipes/discover/\(sourceID.uuidString)" {
                return (
                    Self.response(request),
                    try! Self.refreshedRecipeFixture()
                )
            }
            if request.url?.path == "/refreshed" {
                return (
                    Self.response(request),
                    Data([0xFF, 0xD8, 0xFF])
                )
            }
            // Every other endpoint — /v1/recipes/{id} included — cannot
            // serve a Discover source.
            return (Self.response(request, status: 404), Data())
        }
        let cache = makeCache(directory: directory)

        let local: URL
        do {
            local = try await cache.localURL(
                owner: .discoverSource(id: sourceID),
                image: RemoteRecipeImageDTO(
                    id: sourceID,
                    remoteURL: URL(
                        string: "https://images.ladle.test/expired"
                    )!
                )
            )
        } catch {
            XCTFail(
                "Refreshing an expired Discover thumbnail must succeed"
                    + " through the Discover detail, but requested"
                    + " \(paths.snapshot)"
            )
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(
            paths.snapshot.filter {
                $0.contains("/v1/recipes/discover/")
            }.count,
            1
        )
        XCTAssertEqual(
            paths.snapshot.filter { $0.contains("/refreshed") }.count,
            1
        )
    }

    func testDiscoverRefreshFailsWhenTheDetailHasNoThumbnail()
        async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        URLProtocolStub.install { request in
            if request.url?.host == "images.ladle.test" {
                return (Self.response(request, status: 403), Data())
            }
            if request.url?.path.hasPrefix("/v1/recipes/discover/")
                == true {
                return (
                    Self.response(request),
                    try! Self.refreshedRecipeFixture(includesImage: false)
                )
            }
            return (Self.response(request, status: 404), Data())
        }

        do {
            _ = try await makeCache(directory: directory).localURL(
                owner: .discoverSource(id: UUID()),
                image: RemoteRecipeImageDTO(
                    id: UUID(),
                    remoteURL: URL(
                        string: "https://images.ladle.test/expired"
                    )!
                )
            )
            XCTFail("Expected missing refreshed thumbnail")
        } catch {
            XCTAssertEqual(
                error as? RemoteImageCacheError,
                .refreshedImageMissing
            )
        }
    }

    func testArtworkFailurePresentationIsExplicit() {
        XCTAssertEqual(
            RecipeArtworkLoadState.failed.systemImage,
            "photo.badge.exclamationmark"
        )
        XCTAssertEqual(
            RecipeArtworkLoadState.failed.accessibilityLabel,
            "Recipe image unavailable"
        )
    }

    // MARK: - The detail screen's artwork owner must follow its access

    @MainActor
    func testDiscoverAccessDetailRefreshesItsExpiredHeroImageThroughTheDiscoverDetail()
        async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A pushed Discover detail's recipe id IS the Discover sourceID —
        // the server instantiates the preview with
        // recipe_id=source_video_id — so /v1/recipes/{id} can never
        // refresh its expired thumbnail.
        let sourceID = UUID(
            uuidString: "91000000-0000-4000-8000-000000000001"
        )!
        let expired = URL(string: "https://images.ladle.test/expired")!
        let detail = makeRecipeDetailView(
            recipe: discoverPreviewRecipe(
                sourceID: sourceID,
                imageURL: expired
            ),
            access: .discover
        )

        let paths = Locked<[String]>([])
        URLProtocolStub.install { request in
            paths.withValue {
                $0.append(request.url?.absoluteString ?? "")
            }
            if request.url?.path == "/expired" {
                return (Self.response(request, status: 403), Data())
            }
            if request.url?.path
                == "/v1/recipes/discover/\(sourceID.uuidString)" {
                return (
                    Self.response(request),
                    try! Self.refreshedRecipeFixture()
                )
            }
            if request.url?.path == "/refreshed" {
                return (
                    Self.response(request),
                    Data([0xFF, 0xD8, 0xFF])
                )
            }
            // A Discover source is not a recipe in the caller's own
            // library — /v1/recipes/{sourceID} included, every other
            // path 404s.
            return (Self.response(request, status: 404), Data())
        }
        let cache = makeCache(directory: directory)

        let local: URL
        do {
            local = try await cache.localURL(
                owner: detail.artworkOwner,
                image: RemoteRecipeImageDTO(
                    id: sourceID,
                    remoteURL: expired
                )
            )
        } catch {
            XCTFail(
                "A Discover-access detail must refresh its expired hero"
                    + " image through the Discover detail, but requested"
                    + " \(paths.snapshot)"
            )
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(
            paths.snapshot.filter {
                $0.contains("/v1/recipes/discover/")
            }.count,
            1
        )
        XCTAssertTrue(
            paths.snapshot.allSatisfy {
                !$0.contains("/v1/recipes/\(sourceID.uuidString)")
            },
            "The doomed library-recipe lookup must never be issued"
        )
    }

    @MainActor
    func testSavedAccessDetailKeepsRefreshingThroughItsOwnRecipe() {
        let recipe = discoverPreviewRecipe(
            sourceID: UUID(
                uuidString: "92000000-0000-4000-8000-000000000001"
            )!,
            imageURL: URL(string: "https://images.ladle.test/fresh")!
        )

        let detail = makeRecipeDetailView(recipe: recipe, access: .saved)

        XCTAssertEqual(detail.artworkOwner, .recipe(id: recipe.id))
    }

    func testDetailHeroImageIsWiredToTheAccessOwner() throws {
        // The composed tests above pin the owner decision; this pins the
        // wiring so the hero image cannot quietly go back to the bare
        // recipeID convenience.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Ladle/RecipeDetail/RecipeDetailView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("owner: artworkOwner"))
        XCTAssertFalse(source.contains("recipeID: displayedRecipe.id"))
    }

    @MainActor
    private func makeRecipeDetailView(
        recipe: Recipe,
        access: LibraryRecipeAccess
    ) -> RecipeDetailView {
        RecipeDetailView(
            recipe: recipe,
            statusText: access == .discover
                ? "Discover recipe"
                : "Saved recipe",
            importCoordinator: ImportCoordinator(
                repository: ArtworkTestRepository(),
                service: ArtworkTestImportService(),
                accountSession: AccountSession(
                    store: ArtworkTestPreferenceStore(),
                    launchArguments: []
                )
            ),
            makeEditorViewModel: { _ in
                fatalError("The artwork tests never open the editor")
            },
            recipeDidChange: { _ in },
            toggleFavorite: { _ in false },
            access: access,
            openAccount: {}
        )
    }

    private func discoverPreviewRecipe(
        sourceID: UUID,
        imageURL: URL
    ) -> Recipe {
        // Mirrors DiscoverRecipe.watchPreview / the server's Discover
        // detail: the recipe id and the client-minted image id are both
        // the sourceID.
        Recipe(
            id: sourceID,
            title: "Charred corn ribs",
            description: "",
            creatorName: "@ladle",
            source: .tiktok,
            originalURL: URL(
                string: "https://www.tiktok.com/@ladle/video/1"
            )!,
            images: [RecipeImage(id: sourceID, remoteURL: imageURL)],
            servings: 1
        )
    }

    private func makeCache(directory: URL) -> RemoteImageCache {
        let session = URLProtocolStub.session()
        return RemoteImageCache(
            directoryURL: directory,
            session: session,
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: session,
                tokenStore: InMemoryAuthTokenStore(
                    tokens: .fixture(accessToken: "access")
                )
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    nonisolated private static func response(
        _ request: URLRequest,
        status: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    nonisolated private static func refreshedRecipeFixture(
        includesImage: Bool = true
    ) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root
            .appendingPathComponent("Contracts/Fixtures/recipe-ready.json")
        let value = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture)
        ) as! [String: Any]
        var changed = value
        if includesImage {
            var images = changed["images"] as! [[String: Any]]
            images[0]["remoteURL"] =
                "https://images.ladle.test/refreshed"
            changed["images"] = images
        } else {
            changed["images"] = []
        }
        return try JSONSerialization.data(withJSONObject: changed)
    }
}


@MainActor
private final class ArtworkTestRepository: RecipeRepository {
    func fetchRecipes() throws -> [Recipe] { [] }
    func fetchRecipe(id: UUID) throws -> Recipe? { nil }
    func save(_ recipe: Recipe) throws {}
    func deleteRecipe(id: UUID) throws {}
    func fetchImportJobs() throws -> [ImportJob] { [] }
    func save(_ importJob: ImportJob) throws {}
    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {}
}

private struct ArtworkTestImportService: ImportService {
    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        throw APIError.invalidResponse
    }

    func status(
        remoteJobID: String
    ) async throws -> ImportServiceUpdate {
        throw APIError.invalidResponse
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        throw APIError.invalidResponse
    }
}

private final class ArtworkTestPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}
