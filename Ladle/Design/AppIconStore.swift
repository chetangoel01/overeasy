import LadleCore
import Observation
import SwiftUI
import UIKit

/// The two icons Overeasy ships with.
///
/// The app is named after an egg, and a cook who does not eat eggs should
/// not have to carry one on their home screen. That is the whole feature:
/// the egg the app shipped with, and one plant-based alternate.
///
/// The plant-based artwork is a **placeholder** — the Bowl candidate from
/// the icon-candidate board, as rendered. Replacing it is replacing the PNG
/// in `AppIcon-PlantBased.appiconset` and its drawable twin in
/// `OvereasyMarkPlantBased.imageset`; no code here moves with it.
enum LadleAppIcon: String, CaseIterable, Identifiable {
    case egg
    case plantBased

    var id: String { rawValue }

    /// What iOS calls this icon. `nil` is how it spells the primary one.
    var alternateIconName: String? {
        switch self {
        case .egg: nil
        case .plantBased: "AppIcon-PlantBased"
        }
    }

    var title: String {
        switch self {
        case .egg: "Egg"
        case .plantBased: "Plant-based"
        }
    }

    /// The picker cannot draw an `appiconset`: it is compiled into
    /// `Assets.car` as an icon rather than an image, and `UIImage(named:)`
    /// does not find it. Each icon therefore keeps a byte-identical twin in
    /// an `imageset`, and this is its name.
    var markImageName: String {
        switch self {
        case .egg: "OvereasyMark"
        case .plantBased: "OvereasyMarkPlantBased"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .egg: "account.app-icon.egg"
        case .plantBased: "account.app-icon.plant-based"
        }
    }

    init(alternateIconName: String?) {
        self =
            Self.allCases.first { $0.alternateIconName == alternateIconName }
            ?? .egg
    }
}

/// Changing the icon, as something other than `UIApplication`.
///
/// Only so the store can be handed a fake: switching an icon for real needs
/// a home screen, which a test does not have.
@MainActor
protocol AlternateAppIconSetting: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ alternateIconName: String?) async throws
}

extension UIApplication: AlternateAppIconSetting {}

/// Which icon is installed, and the one time the app asks about it.
@MainActor
@Observable
final class AppIconStore {
    /// Whether the question has been put to this cook. In the app's own
    /// preference domain beside the accent, and written rather than removed
    /// when a launch resets it — see `LibraryViewModel.resetPreferences`.
    static let offerPreferenceKey = "ladle.appearance.plant-based-icon-offered"

    /// The icon on the home screen right now. iOS holds this, not us: there
    /// is no preference of our own to keep in step with it.
    private(set) var icon: LadleAppIcon

    /// Whether the one-time offer is on screen.
    var isOfferPresented = false

    @ObservationIgnored
    private let application: any AlternateAppIconSetting

    @ObservationIgnored
    private let preferenceStore: any PreferenceStoring

    init(
        application: any AlternateAppIconSetting = UIApplication.shared,
        preferenceStore: any PreferenceStoring = UserDefaults.standard
    ) {
        self.application = application
        self.preferenceStore = preferenceStore
        icon = LadleAppIcon(alternateIconName: application.alternateIconName)
    }

    var canChooseAnIcon: Bool { application.supportsAlternateIcons }

    /// Switch icons. iOS puts up its own alert about it, which is the
    /// system's business and is deliberately left alone — the picker adds
    /// no confirmation of its own in front of it.
    ///
    /// The selection is read back from the system rather than assumed from
    /// what was asked for, so a refused switch leaves the picker showing
    /// the icon that is actually installed.
    func select(_ icon: LadleAppIcon) async {
        guard icon != self.icon else { return }
        try? await application.setAlternateIconName(icon.alternateIconName)
        self.icon = LadleAppIcon(
            alternateIconName: application.alternateIconName
        )
    }

    /// Ask, once, when the cook's diet first makes the question relevant.
    ///
    /// Nothing switches on its own: this only raises the question, and the
    /// cook answers it. The flag is spent on asking rather than on the
    /// answer, so an app that dies with the alert up has still asked.
    ///
    /// A cook already carrying the plant-based icon is not asked to choose
    /// what they already have, and their question is left unspent for
    /// whenever they go back to the egg.
    func offerIfNeeded(for diets: Set<DietTag>) {
        guard
            application.supportsAlternateIcons,
            icon == .egg,
            diets.contains(.vegetarian) || diets.contains(.vegan),
            !preferenceStore.bool(forKey: Self.offerPreferenceKey)
        else { return }

        preferenceStore.set(true, forKey: Self.offerPreferenceKey)
        isOfferPresented = true
    }

    func acceptOffer() async {
        isOfferPresented = false
        await select(.plantBased)
    }

    /// Put the question back for the next launch.
    ///
    /// Written `false` rather than removed, for the reason the accent is
    /// written: a value seeded from outside the app — `simctl spawn
    /// defaults write` lands in the simulator's device-level domain — is
    /// read through but cannot be deleted, so only a write in the app's own
    /// domain clears it. The installed icon is not reset with it; that is
    /// the home screen's, not a preference of ours.
    static func resetPreferences(
        in preferenceStore: any PreferenceStoring = UserDefaults.standard
    ) {
        preferenceStore.set(false, forKey: offerPreferenceKey)
    }
}
