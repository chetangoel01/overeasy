import AuthenticationServices
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
            SignInWithAppleButton(.continue) { request in
                flow.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await flow.handleAppleCompletion(result) }
            }
            // Always white. The welcome surface is unconditionally graphite,
            // so a style chosen from the device appearance is wrong half the
            // time: `colorScheme` here resolves outside this view's own
            // `.environment(\.colorScheme, .dark)`, so on a light-mode device
            // it picked `.black` and painted a black button onto #14181B.
            .signInWithAppleButtonStyle(.white)
            .frame(height: LadleTheme.Control.primary)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control
                )
            )
            .disabled(flow.isAuthenticating)

            GoogleSignInControl(
                isEnabled: !flow.isAuthenticating,
                accessibilityIdentifier: "welcome.google-sign-in"
            ) {
                Task { await flow.signInWithGoogle() }
            }
            .padding(.top, LadleTheme.Spacing.medium)

            guestSeparator
                .padding(.vertical, LadleTheme.Spacing.medium)

            Button {
                Task { await flow.continueAsGuest() }
            } label: {
                Text("Try as a guest")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .frame(maxWidth: .infinity, minHeight: LadleTheme.Control.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(flow.isAuthenticating)

            Text(
                "Guests can save up to 10 recipes. Sign in later without losing them."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.onAccent.opacity(0.72))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, LadleTheme.Spacing.compact)

            if flow.isAuthenticating {
                ProgressView("Setting up Overeasy")
                    .ladleFont(.metadata)
                    .tint(accent.intent)
                    .foregroundStyle(LadleTheme.Label.onAccent.opacity(0.8))
                    .padding(.top, LadleTheme.Spacing.medium)
            }

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
            Image("GoogleSignInNeutral")
                .resizable()
                .scaledToFit()
                .frame(width: 188, height: 44)
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: LadleTheme.Control.primary)
            .background(
                LadleTheme.Label.onAccent,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
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
