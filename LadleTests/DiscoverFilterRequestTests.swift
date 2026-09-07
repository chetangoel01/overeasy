import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// Discover and Watch never thin a page they were handed: the filter goes
/// out with the request. These pin the wire shape, because an off-vocabulary
/// value is a 422 rather than a silent match-everything, and a repeated
/// parameter is the only way the endpoint hears more than one value.
@MainActor
final class DiscoverFilterRequestTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testEveryFamilyTravelsAsItsOwnRepeatedParameter() async throws {
        let captured = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            captured.withValue { $0.append(request) }
            return (
                Self.response(request),
                Self.emptyPage()
            )
        }
        let service = RemoteDiscoverService(api: Self.client())
        var filter = RecipeFilter(
            diets: [.dairyFree, .vegan],
            cuisines: [.korean, .american],
            keywords: [.weeknight, .onePot]
        )
        filter.addIngredient("Chicken Thigh")
        filter.addIngredient("gochujang")

        _ = try await service.fetchDiscoverPage(
            cursor: 0,
            query: "",
            sort: .popular,
            filter: filter
        )

        let request = try XCTUnwrap(captured.snapshot.first)
        let components = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )
        )
        let items = components.queryItems ?? []
        // Vocabulary order, not the order a cook happened to tap in: a set
        // has none, and a request that reordered itself between launches
        // would be untestable and uncacheable.
        XCTAssertEqual(
            items.filter { $0.name == "diet" }.map(\.value),
            ["vegan", "dairyFree"]
        )
        XCTAssertEqual(
            items.filter { $0.name == "cuisine" }.map(\.value),
            ["american", "korean"]
        )
        XCTAssertEqual(
            items.filter { $0.name == "keyword" }.map(\.value),
            ["onePot", "weeknight"]
        )
        // Terms keep the order they were typed in, lower-cased on the way
        // into the filter so the server matches what the cook meant.
        XCTAssertEqual(
            items.filter { $0.name == "ingredient" }.map(\.value),
            ["chicken thigh", "gochujang"]
        )
    }

    func testAnEmptyFilterAddsNothingToTheRequest() async throws {
        let captured = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            captured.withValue { $0.append(request) }
            return (Self.response(request), Self.emptyPage())
        }
        let service = RemoteDiscoverService(api: Self.client())

        _ = try await service.fetchDiscoverPage(
            cursor: 0,
            query: "",
            sort: .popular
        )

        let request = try XCTUnwrap(captured.snapshot.first)
        let items = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        XCTAssertEqual(
            Set(items.map(\.name)),
            ["cursor", "limit", "sort"]
        )
    }

    private static func client() -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: InMemoryAuthTokenStore(
                tokens: .fixture(accessToken: "guest-access")
            )
        )
    }

    /// `nonisolated`: the stub's handler runs off the main actor, and a
    /// helper on a `@MainActor` test case would otherwise be unreachable
    /// from inside it.
    nonisolated private static func response(
        _ request: URLRequest
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func emptyPage() -> Data {
        Data(
            #"{"items": [], "nextCursor": 0, "hasMore": false}"#.utf8
        )
    }
}
