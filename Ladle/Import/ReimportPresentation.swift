import SwiftUI

/// Pairs a sheet's claim to be presenting re-import outcomes with the
/// release that retires the claim, in one modifier: appearing registers
/// the presentation with the coordinator, disappearing ends it. Close,
/// swipe-down, and structural teardown all funnel through the same
/// `endReimportPresentation`, so no way of leaving a declared sheet can
/// strand a finished re-import published and wedge Add Recipe behind
/// "Re-import in progress". A sheet with no recipe to present
/// (`recipeID == nil`, a plain import row) is inert.
private struct ReimportPresentationModifier: ViewModifier {
    let coordinator: ImportCoordinator
    let recipeID: UUID?

    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let recipeID else { return }
                coordinator.beginReimportPresentation(
                    token,
                    for: recipeID
                )
            }
            .onDisappear {
                coordinator.endReimportPresentation(token)
            }
    }
}

extension View {
    /// Declares this sheet as a presentation of re-import outcomes for
    /// `recipeID`. Every sheet that can start, retry, or resume a
    /// re-import must carry this — the attach and the release travel
    /// together here, and a source pin
    /// (`testEverySheetDrivingAReimportCarriesThePairedPresentation`)
    /// keeps a future sheet from driving one without it. Apply it to
    /// the sheet's whole body, never inside a conditional branch.
    func reimportPresentation(
        _ coordinator: ImportCoordinator,
        for recipeID: UUID?
    ) -> some View {
        modifier(ReimportPresentationModifier(
            coordinator: coordinator,
            recipeID: recipeID
        ))
    }
}
