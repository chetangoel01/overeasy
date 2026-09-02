import XCTest
@testable import Ladle

/// The one line under the cook's name. Its wording is the whole of it, so
/// it is asserted here rather than read off a screenshot.
@MainActor
final class ProfileFactsTests: XCTestCase {
    private let august = ISO8601DateFormatter().date(
        from: "2026-08-14T12:00:00Z"
    )!

    func testSignedInLineCountsRecipesFavoritesAndTheFirstMonth() {
        XCTAssertEqual(
            ProfileFacts.line(
                for: .signedInWithGoogle,
                recipes: 6,
                favorites: 2,
                createdAt: august
            ),
            "6 recipes · 2 favorites · cooking since August 2026"
        )
    }

    /// American spelling and English plurals: "1 recipe", not "1 recipes",
    /// and "favorite", not "favourite" — every other string in the app is
    /// American even though the documents around it are not.
    func testSingularCountsDropTheirPlural() {
        XCTAssertEqual(
            ProfileFacts.line(
                for: .signedInWithApple,
                recipes: 1,
                favorites: 1,
                createdAt: august
            ),
            "1 recipe · 1 favorite · cooking since August 2026"
        )
    }

    func testZeroCountsStayPlural() {
        XCTAssertEqual(
            ProfileFacts.line(
                for: .signedInWithApple,
                recipes: 0,
                favorites: 0,
                createdAt: august
            ),
            "0 recipes · 0 favorites · cooking since August 2026"
        )
    }

    /// An account created before the date reached the wire, or a Keychain
    /// record written by an older build. The line shortens; it does not
    /// invent a month or print an empty one.
    func testAnUnknownCreationDateDropsCookingSince() {
        XCTAssertEqual(
            ProfileFacts.line(
                for: .signedInWithGoogle,
                recipes: 6,
                favorites: 2,
                createdAt: nil
            ),
            "6 recipes · 2 favorites"
        )
    }

    /// A guest has no synced library and no account to have started, so the
    /// line says where the recipes are instead of when they began.
    func testGuestLineIsAboutThisDevice() {
        XCTAssertEqual(
            ProfileFacts.line(
                for: .guest,
                recipes: 6,
                favorites: 2,
                createdAt: august
            ),
            "6 recipes on this device"
        )
        XCTAssertEqual(
            ProfileFacts.line(
                for: .guest,
                recipes: 1,
                favorites: 0,
                createdAt: nil
            ),
            "1 recipe on this device"
        )
        XCTAssertEqual(
            ProfileFacts.line(
                for: .undecided,
                recipes: 0,
                favorites: 0,
                createdAt: nil
            ),
            "0 recipes on this device"
        )
    }

    /// The title the header prints under the name is untouched by any of
    /// this — the provider line is the same string it always was.
    func testAccountTitleIsUnchanged() {
        XCTAssertEqual(
            AccountSheet.accountTitle(for: .signedInWithGoogle),
            "Signed in with Google"
        )
        XCTAssertEqual(
            AccountSheet.accountTitle(for: .signedInWithApple),
            "Signed in with Apple"
        )
        XCTAssertEqual(
            AccountSheet.accountTitle(for: .guest),
            "Using Overeasy as a guest"
        )
    }
}
