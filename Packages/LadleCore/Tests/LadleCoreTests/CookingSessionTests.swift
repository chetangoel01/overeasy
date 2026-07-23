import Foundation
import Testing
@testable import LadleCore

@Suite("Cooking session")
struct CookingSessionTests {
    @Test
    func navigationClampsToAvailableSteps() {
        let stepIDs = [UUID(), UUID(), UUID()]
        var session = CookingSession(stepIDs: stepIDs)

        session.movePrevious()
        #expect(session.currentStepIndex == 0)

        session.moveNext()
        session.moveNext()
        session.moveNext()
        #expect(session.currentStepIndex == 2)
        #expect(session.currentStepID == stepIDs[2])
    }

    @Test
    func modeSwitchingPreservesCurrentPosition() {
        var session = CookingSession(stepIDs: [UUID(), UUID(), UUID()])
        session.moveNext()

        session.setMode(.focus)
        #expect(session.currentStepIndex == 1)

        session.setMode(.fullRecipe)
        #expect(session.currentStepIndex == 1)
    }

    @Test
    func completionStateIsSharedAcrossModes() {
        let stepID = UUID()
        let ingredientID = UUID()
        var session = CookingSession(stepIDs: [stepID])

        session.toggleCompletedStep(stepID)
        session.toggleCompletedIngredient(ingredientID)
        session.setMode(.focus)

        #expect(session.completedStepIDs == [stepID])
        #expect(session.completedIngredientIDs == [ingredientID])
    }

    @Test
    func togglingACompletedItemAgainUnchecksIt() {
        let stepID = UUID()
        var session = CookingSession(stepIDs: [stepID])

        session.toggleCompletedStep(stepID)
        session.toggleCompletedStep(stepID)

        #expect(session.completedStepIDs.isEmpty)
    }
}
