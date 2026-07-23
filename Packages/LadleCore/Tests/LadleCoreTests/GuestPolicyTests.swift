import Foundation
import Testing
@testable import LadleCore

@Suite("Guest recipe limit")
struct GuestPolicyTests {
    @Test
    func countsBelowNineAllowSavingWithoutPrompt() {
        for count in 0 ... 8 {
            #expect(GuestPolicy.decision(savedRecipeCount: count) == .allow)
        }
    }

    @Test
    func ninthSavedRecipePromptsBeforeTheTenthSave() {
        #expect(
            GuestPolicy.decision(savedRecipeCount: 9)
                == .allowWithAccountPrompt
        )
    }

    @Test
    func tenSavedRecipesReachTheGuestLimit() {
        #expect(
            GuestPolicy.decision(savedRecipeCount: 10)
                == .limitReached
        )
    }

    @Test
    func limitNeverBlocksExistingRecipes() {
        let savedRecipeID = UUID()

        #expect(
            GuestPolicy.canOpenExistingRecipe(
                savedRecipeID,
                savedRecipeIDs: [savedRecipeID],
                savedRecipeCount: 10
            )
        )
    }
}
