import SwiftUI

struct WelcomeView: View {
    let accountSession: AccountSession

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                LadleSheetHandle()

                Image(systemName: "fork.knife")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(LadleTheme.paprika)
                    .frame(width: 50, height: 50)
                    .background(LadleTheme.review, in: Circle())
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("WELCOME TO LADLE")
                        .font(LadleTypography.eyebrow)
                        .tracking(1.7)
                        .foregroundStyle(LadleTheme.paprika)

                    Text("Recipes, rescued\nfrom the scroll.")
                        .font(LadleTypography.title)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(LadleTheme.ink)
                        .accessibilityLabel(
                            "Recipes, rescued from the scroll."
                        )

                    Text(
                        "Share a recipe video once. Ladle turns it into a clean recipe you can actually cook."
                    )
                    .font(LadleTypography.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LadleTheme.ink.opacity(0.67))
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 14) {
                    WelcomeFeature(
                        icon: "square.and.arrow.up",
                        text: "Share from TikTok, Instagram, or YouTube"
                    )
                    WelcomeFeature(
                        icon: "text.badge.checkmark",
                        text: "Get clear ingredients, steps, and nutrition"
                    )
                    WelcomeFeature(
                        icon: "flame",
                        text: "Cook hands-free with focused, readable steps"
                    )
                }

                VStack(spacing: 11) {
                    Button(action: accountSession.signInWithApple) {
                        Label("Sign in with Apple", systemImage: "apple.logo")
                    }
                    .buttonStyle(LadlePrimaryButtonStyle())

                    Button(action: accountSession.createFreeAccount) {
                        Text("Create a free account")
                    }
                    .buttonStyle(
                        LadlePrimaryButtonStyle(isProminent: false)
                    )

                    Button(action: accountSession.continueAsGuest) {
                        Text("Continue as a guest")
                            .font(LadleTypography.bodyStrong)
                            .foregroundStyle(LadleTheme.ink)
                            .frame(minHeight: 38)
                    }

                    Text("Guests can save up to 10 recipes.")
                        .font(LadleTypography.metadata)
                        .foregroundStyle(LadleTheme.ink.opacity(0.55))
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.generous)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 700)
        .background(
            LadleTheme.paper,
            in: UnevenRoundedRectangle(
                topLeadingRadius: LadleTheme.Corner.sheet,
                topTrailingRadius: LadleTheme.Corner.sheet
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.sheet")
    }
}

private struct WelcomeFeature: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 34, height: 34)
                .background(LadleTheme.review, in: Circle())
            Text(text)
                .font(LadleTypography.body)
                .foregroundStyle(LadleTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
