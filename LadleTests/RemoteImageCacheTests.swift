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
