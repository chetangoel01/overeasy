import SwiftUI

struct WelcomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    @State private var flow: AccountSignInFlow

    init(
        accountSession: AccountSession,
        authClient: AuthClient?,
        googleSignIn: (any GoogleSignInProviding)?,
        onAuthenticated: @escaping @MainActor () async -> Void
    ) {
        _flow = State(
            initialValue: AccountSignInFlow(
                accountSession: accountSession,
                authClient: authClient,
                googleSignIn: googleSignIn,
                onAuthenticated: onAuthenticated
            )
        )
    }

    var body: some View {
        ZStack {
            LadleTheme.Surface.graphite
                .ignoresSafeArea()

            GeometryReader { proxy in
                let verticalPadding: CGFloat =
                    dynamicTypeSize.isAccessibilitySize ? 16 : 24

                if Self.usesScrollingLayout(for: dynamicTypeSize) {
                    ScrollView {
                        welcomeContent(
                            minimumHeight: proxy.size.height
                                - (verticalPadding * 2),
                            verticalPadding: verticalPadding
                        )
                    }
                    .scrollIndicators(.hidden)
                } else {
                    welcomeContent(
                        minimumHeight: proxy.size.height
                            - (verticalPadding * 2),
                        verticalPadding: verticalPadding
                    )
                }
            }
        }
        // The welcome surface is always graphite; render on-dark colors.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.full-screen")
    }

    private func welcomeContent(
        minimumHeight: CGFloat,
        verticalPadding: CGFloat
    ) -> some View {
        VStack(
            spacing: dynamicTypeSize.isAccessibilitySize
                ? LadleTheme.Spacing.generous
                : LadleTheme.Spacing.cooking
        ) {
            welcomeIntroduction
            accountActions
        }
        .frame(
            minHeight: max(minimumHeight, 0),
            alignment: .center
        )
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.vertical, verticalPadding)
    }

    static func usesScrollingLayout(
        for dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var welcomeIntroduction: some View {
        VStack(spacing: LadleTheme.Spacing.regular) {
            welcomeMark
            welcomeMessage
        }
    }

    private var welcomeMark: some View {
        Image("OvereasyMark")
            .resizable()
            .scaledToFit()
            .frame(
                width: dynamicTypeSize.isAccessibilitySize ? 84 : 96,
                height: dynamicTypeSize.isAccessibilitySize ? 84 : 96
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 24,
                    style: .continuous
                )
            )
            .accessibilityLabel("Overeasy app icon")
            .accessibilityIdentifier("welcome.brand-mark")
    }

    private var welcomeMessage: some View {
        VStack(spacing: LadleTheme.Spacing.compact) {
            Text("Overeasy")
                .ladleFont(.section)
                .foregroundStyle(accent.label)

            Text("Recipes, rescued from the scroll.")
                .ladleScaledFont(
                    size: 29,
                    relativeTo: .title,
                    weight: .bold
                )
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(LadleTheme.Label.onAccent)

            Text(
                "Save recipe videos as something you can actually cook."
            )
            .ladleFont(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(LadleTheme.Label.onAccent.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
    }

    private var accountActions: some View {
        VStack(spacing: 0) {
            SignInOptionsView(
                flow: flow,
                identifierPrefix: "welcome",
                surface: .graphite
            )

            guestSeparator
                .padding(.vertical, LadleTheme.Spacing.medium)

            // The progress state replaces the button's own label rather than
            // appending a row beneath it. This stack is centred inside the
            // screen, so anything added at the bottom pushed the logo, the
            // headline and both sign-in buttons visibly upward the instant
            // the guest button was tapped.
            Button {
                Task { await flow.continueAsGuest() }
            } label: {
                Group {
                    if flow.isAuthenticating {
                        HStack(spacing: LadleTheme.Spacing.compact) {
                            ProgressView()
                                .tint(accent.intent)
                            Text("Setting up Overeasy")
                        }
                    } else {
                        Text("Try as a guest")
                    }
                }
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: LadleTheme.Control.hitTarget
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(flow.isAuthenticating)

            if let authenticationFailure = flow.failure {
                Text(authenticationFailure.message)
                    .ladleFont(.metadata)
                    .foregroundStyle(accent.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LadleTheme.Spacing.medium)
            }
        }
    }

    private var guestSeparator: some View {
        HStack(spacing: LadleTheme.Spacing.medium) {
            Rectangle()
                .fill(LadleTheme.Label.onAccent.opacity(0.24))
                .frame(height: 1)
            Text("or")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.onAccent.opacity(0.7))
            Rectangle()
                .fill(LadleTheme.Label.onAccent.opacity(0.24))
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }

}

struct GoogleSignInControl: View {
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            // Google ships this as a finished button: pill, border and all.
            // It is the control, not a glyph to be mounted inside one, so it
            // takes whatever frame the caller gives it and keeps its aspect.
            Image("GoogleSignInNeutral")
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        }
        .buttonStyle(GoogleSignInButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("Sign in with Google")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct GoogleSignInButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    /// Deliberately paints no background. The asset already carries Google's
    /// own pill and border, and a second one behind it rendered a button
    /// inside a button — a full-width white card with a smaller grey pill
    /// floating in the middle of it.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(
                !isEnabled
                    ? 0.48
                    : (configuration.isPressed ? 0.72 : 1)
            )
            .scaleEffect(
                reduceMotion || !isEnabled
                    ? 1
                    : (configuration.isPressed ? 0.985 : 1)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
