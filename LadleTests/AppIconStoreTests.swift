import LadleCore
import XCTest
@testable import Ladle

/// Icon selection, and the one time the app asks about it.
///
/// The switching itself is iOS's, so what is worth pinning here is the part
/// that is ours: which name is set for which icon, that the question is
/// asked once and only of a cook whose diet makes it relevant, and that a
/// reset puts the question back.
@MainActor
final class AppIconStoreTests: XCTestCase {
    func testEveryShippedIconCanBeSelectedAndRestored() async {
        let expected: [(title: String, name: String?)] = [
            ("Egg", nil),
            ("Avocado", "AppIcon-PlantBased"),
            ("Tomato", "AppIcon-Tomato"),
            ("Strawberry", "AppIcon-Strawberry"),
            ("Cherries", "AppIcon-Cherries"),
            ("Carrot", "AppIcon-Carrot"),
            ("Mushroom", "AppIcon-Mushroom"),
        ]
        XCTAssertEqual(LadleAppIcon.allCases.map(\.title), expected.map(\.title))

        for (title, name) in expected {
            guard let icon = LadleAppIcon.allCases.first(where: { $0.title == title }) else {
                XCTFail("Missing icon: \(title)")
                continue
            }
            let application = FakeAlternateIcons()
            let store = AppIconStore(
                application: application,
                preferenceStore: IconPreferences()
            )

            await store.select(icon)

            XCTAssertEqual(application.alternateIconName, name, title)
            XCTAssertEqual(store.icon, icon, title)
            let reopened = AppIconStore(
                application: application,
                preferenceStore: IconPreferences()
            )
            XCTAssertEqual(reopened.icon, icon, title)
        }
    }

    /// `nil` is how iOS spells "the icon the app shipped with".
    func testGoingBackToTheEggClearsTheAlternateName() async {
        let application = FakeAlternateIcons(
            alternateIconName: "AppIcon-PlantBased"
        )
        let store = AppIconStore(
            application: application,
            preferenceStore: IconPreferences()
        )

        await store.select(.egg)

        XCTAssertEqual(application.requests, [String?.none])
        XCTAssertEqual(store.icon, .egg)
    }

    /// The picker has no preference of its own to read: the installed icon
    /// is the selection, and iOS is the one holding it.
    func testTheStoreOpensOnWhicheverIconIsInstalled() {
        let plantBased = AppIconStore(
            application: FakeAlternateIcons(
                alternateIconName: "AppIcon-PlantBased"
            ),
            preferenceStore: IconPreferences()
        )
        let egg = AppIconStore(
            application: FakeAlternateIcons(),
            preferenceStore: IconPreferences()
        )

        XCTAssertEqual(plantBased.icon, .avocado)
        XCTAssertEqual(egg.icon, .egg)
    }

    /// A failed switch leaves the picker showing the icon that is actually
    /// installed rather than the one that was asked for.
    func testARefusedSwitchLeavesTheSelectionWhereItWas() async {
        let application = FakeAlternateIcons()
        application.failure = IconTestError.refused
        let store = AppIconStore(
            application: application,
            preferenceStore: IconPreferences()
        )

        await store.select(.avocado)

        XCTAssertEqual(store.icon, .egg)
    }

    func testTheOfferIsMadeOnceToAVegetarianCook() {
        let preferences = IconPreferences()
        let store = AppIconStore(
            application: FakeAlternateIcons(),
            preferenceStore: preferences
        )

        store.offerIfNeeded(for: [.vegetarian])
        XCTAssertTrue(store.isOfferPresented)

        store.isOfferPresented = false
        store.offerIfNeeded(for: [.vegetarian, .glutenFree])
        XCTAssertFalse(
            store.isOfferPresented,
            "A question already asked is not a question"
        )

        // A second launch reads the same flag rather than its own memory.
        let later = AppIconStore(
            application: FakeAlternateIcons(),
            preferenceStore: preferences
        )
        later.offerIfNeeded(for: [.vegan])
        XCTAssertFalse(later.isOfferPresented)
    }

    func testAVeganCookIsAskedAndEveryOtherDietIsNot() {
        for diet in DietTag.allCases {
            let store = AppIconStore(
                application: FakeAlternateIcons(),
                preferenceStore: IconPreferences()
            )

            store.offerIfNeeded(for: [diet])

            XCTAssertEqual(
                store.isOfferPresented,
                diet == .vegetarian || diet == .vegan,
                "\(diet) was handled the wrong way"
            )
        }
    }

    func testNoDietIsNeverAsked() {
        let store = AppIconStore(
            application: FakeAlternateIcons(),
            preferenceStore: IconPreferences()
        )

        store.offerIfNeeded(for: [])

        XCTAssertFalse(store.isOfferPresented)
    }

    /// The offer is spent when it is shown, not when it is answered. An app
    /// that dies while the alert is up has still asked.
    func testTheOfferIsSpentWhenItIsShown() {
        let preferences = IconPreferences()
        let store = AppIconStore(
            application: FakeAlternateIcons(),
            preferenceStore: preferences
        )

        store.offerIfNeeded(for: [.vegan])

        XCTAssertTrue(
            preferences.bool(forKey: AppIconStore.offerPreferenceKey)
        )
    }

    func testAcceptingTheOfferSwitchesTheIcon() async {
        let application = FakeAlternateIcons()
        let store = AppIconStore(
            application: application,
            preferenceStore: IconPreferences()
        )
        store.offerIfNeeded(for: [.vegetarian])

        await store.acceptOffer()

        XCTAssertFalse(store.isOfferPresented)
        XCTAssertEqual(store.icon, .avocado)
        XCTAssertEqual(application.requests, ["AppIcon-PlantBased"])
    }

    /// Nothing switches on its own. Declining is the same as never having
    /// been asked, except that it is not asked again.
    func testDecliningTheOfferLeavesTheEgg() {
        let application = FakeAlternateIcons()
        let store = AppIconStore(
            application: application,
            preferenceStore: IconPreferences()
        )

        store.offerIfNeeded(for: [.vegetarian])
        store.isOfferPresented = false

        XCTAssertEqual(store.icon, .egg)
        XCTAssertTrue(application.requests.isEmpty)
    }

    /// A cook already carrying any alternate icon is not asked to choose
    /// what they are already using, and the question is left unspent for
    /// whenever they go back to the egg.
    func testACookAlreadyOnAnyAlternateIconIsNotAsked() {
        for icon in LadleAppIcon.allCases where icon != .egg {
            let preferences = IconPreferences()
            let store = AppIconStore(
                application: FakeAlternateIcons(alternateIconName: icon.alternateIconName),
                preferenceStore: preferences
            )

            store.offerIfNeeded(for: [.vegan])

            XCTAssertFalse(store.isOfferPresented, icon.title)
            XCTAssertFalse(preferences.bool(forKey: AppIconStore.offerPreferenceKey))
        }
    }

    /// A device that cannot change its icon is never asked about it.
    func testAnIconThatCannotBeChangedIsNeverOffered() {
        let application = FakeAlternateIcons()
        application.supportsAlternateIcons = false
        let store = AppIconStore(
            application: application,
            preferenceStore: IconPreferences()
        )

        store.offerIfNeeded(for: [.vegetarian])

        XCTAssertFalse(store.isOfferPresented)
        XCTAssertFalse(store.canChooseAnIcon)
    }

    /// Written `false`, not removed, for the reason the accent is written:
    /// a value seeded into the simulator's device-level domain is read
    /// through but cannot be deleted from the app's own.
    func testResettingLibraryPreferencesAsksAgain() {
        let preferences = IconPreferences()
        preferences.set(true, forKey: AppIconStore.offerPreferenceKey)

        LibraryViewModel.resetPreferences(in: preferences)

        XCTAssertEqual(
            preferences.value(forKey: AppIconStore.offerPreferenceKey) as? Bool,
            false,
            "The flag has to be written false, not taken away"
        )
        let store = AppIconStore(
            application: FakeAlternateIcons(),
            preferenceStore: preferences
        )
        store.offerIfNeeded(for: [.vegetarian])
        XCTAssertTrue(store.isOfferPresented)
    }
}

private enum IconTestError: Error {
    case refused
}

@MainActor
private final class FakeAlternateIcons: AlternateAppIconSetting {
    var supportsAlternateIcons = true
    private(set) var alternateIconName: String?
    private(set) var requests: [String?] = []
    var failure: (any Error)?

    init(alternateIconName: String? = nil) {
        self.alternateIconName = alternateIconName
    }

    func setAlternateIconName(_ alternateIconName: String?) async throws {
        requests.append(alternateIconName)
        if let failure {
            throw failure
        }
        self.alternateIconName = alternateIconName
    }
}

private final class IconPreferences: PreferenceStoring {
    private var values: [String: Any] = [:]

    func value(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

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
        values.removeValue(forKey: defaultName)
    }
}
