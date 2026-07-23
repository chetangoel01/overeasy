import LadleCore
import SwiftUI

struct GuestLimitView: View {
    let decision: GuestSaveDecision
    let accountSession: AccountSession
    var continueAction: () -> Void

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.generous) {
            LadleSheetHandle()

            Image(systemName: "books.vertical")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 54, height: 54)
                .background(LadleTheme.review, in: Circle())

            VStack(spacing: LadleTheme.Spacing.compact) {
                Text(title)
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.65))
                    .multilineTextAlignment(.center)
            }

            Button("Create a free account") {
                accountSession.createFreeAccount()
            }
            .buttonStyle(LadlePrimaryButtonStyle())

            if decision == .allowWithAccountPrompt {
                Button("Save recipe and continue", action: continueAction)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
            }
        }
        .padding(LadleTheme.Spacing.generous)
        .background(LadleTheme.paper)
    }

    private var title: String {
        switch decision {
        case .allow, .allowWithAccountPrompt:
            "One spot left"
        case .limitReached:
            "Your recipes are safe"
        }
    }

    private var message: String {
        switch decision {
        case .allow:
            "You can keep saving recipes as a guest."
        case .allowWithAccountPrompt:
            "This will be your tenth guest recipe. A free account keeps future saves unlimited."
        case .limitReached:
            "Your 10 guest recipes stay available. Create a free account to save another one."
        }
    }
}
