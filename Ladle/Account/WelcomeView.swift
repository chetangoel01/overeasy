import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct WelcomeView: View {
    let accountSession: AccountSession
    let authClient: AuthClient?
    let googleSignIn: (any GoogleSignInProviding)?
    let installationID: String
    let onAuthenticated: @MainActor () async -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var rawNonce: String?
    @State private var isAuthenticating = false
    @State private var authenticationError: String?

    var body: some View {
        ZStack {
            LadleTheme.plum
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
        VStack(spacing: 20) {
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
                .foregroundStyle(LadleTheme.Label.accent)

            Text("Recipes, rescued from the scroll.")
                .ladleScaledFont(
                    size: 29,
                    relativeTo: .title,
                    weight: .bold
                )
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(LadleTheme.onAccent)

            Text(
                "Save recipe videos as something you can actually cook."
            )
            .ladleFont(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(LadleTheme.onAccent.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
    }

    private var accountActions: some View {
        VStack(spacing: 0) {
            SignInWithAppleButton(.continue) { request in
                let nonce = Self.randomNonce()
                rawNonce = nonce
                request.requestedScopes = [.email, .fullName]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                handleAppleCompletion(result)
            }
            // Always white. The welcome surface is unconditionally graphite,
            // so a style chosen from the device appearance is wrong half the
            // time: `colorScheme` here resolves outside this view's own
            // `.environment(\.colorScheme, .dark)`, so on a light-mode device
            // it picked `.black` and painted a black button onto #14181B.
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control
                )
            )
            .disabled(isAuthenticating)

            GoogleSignInControl(isEnabled: !isAuthenticating) {
                authenticateWithGoogle()
            }
            .padding(.top, 10)

            guestSeparator
                .padding(.vertical, 14)

            Button {
                authenticateAsGuest()
            } label: {
                Text("Try as a guest")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAuthenticating)

            Text(
                "Guests can save up to 10 recipes. Sign in later without losing them."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.onAccent.opacity(0.72))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)

            if isAuthenticating {
                ProgressView("Setting up Overeasy")
                    .ladleFont(.metadata)
                    .tint(LadleTheme.brick)
                    .foregroundStyle(LadleTheme.onAccent.opacity(0.8))
                    .padding(.top, LadleTheme.Spacing.medium)
            }

            if let authenticationError {
                Text(authenticationError)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LadleTheme.Spacing.medium)
            }
        }
    }

    private var guestSeparator: some View {
        HStack(spacing: LadleTheme.Spacing.medium) {
            Rectangle()
                .fill(LadleTheme.onAccent.opacity(0.24))
                .frame(height: 1)
            Text("or")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.onAccent.opacity(0.7))
            Rectangle()
                .fill(LadleTheme.onAccent.opacity(0.24))
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private func authenticateWithGoogle() {
        guard !isAuthenticating else {
            return
        }
        guard let googleSignIn else {
            accountSession.signInWithGoogle()
            Task { await onAuthenticated() }
            return
        }
        isAuthenticating = true
        authenticationError = nil
        Task { @MainActor in
            defer { isAuthenticating = false }
            do {
                let identityToken = try await googleSignIn.signIn()
                if let authClient {
                    if try authClient.restoreSession() == nil {
                        _ = try await authClient.bootstrapGuest(
                            installationID: installationID,
                            attestation: nil,
                            applyAccountState: false
                        )
                    }
                    _ = try await authClient.signInWithGoogle(
                        identityToken: identityToken,
                        idempotencyKey: UUID().uuidString.lowercased()
                    )
                } else {
                    accountSession.signInWithGoogle()
                }
                await onAuthenticated()
            } catch GoogleSignInProviderError.cancelled {
                return
            } catch GoogleSignInProviderError.missingConfiguration {
                authenticationError =
                    "Google sign-in isn’t configured for this build."
            } catch {
                authenticationError =
                    "Sign in with Google didn’t complete. Please try again."
            }
        }
    }

    private func authenticateAsGuest() {
        guard !isAuthenticating else {
            return
        }
        isAuthenticating = true
        authenticationError = nil
        Task { @MainActor in
            defer { isAuthenticating = false }
            do {
                if let authClient {
                    _ = try await authClient.bootstrapGuest(
                        installationID: installationID,
                        attestation: nil
                    )
                } else {
                    accountSession.continueAsGuest()
                }
                await onAuthenticated()
            } catch {
                authenticationError =
                    "Overeasy couldn’t connect. Check your connection and try again."
            }
        }
    }

    private func handleAppleCompletion(
        _ result: Result<ASAuthorization, any Error>
    ) {
        guard !isAuthenticating else {
            return
        }
        switch result {
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                authenticationError =
                    "Sign in with Apple didn’t complete. Please try again."
            }
        case let .success(authorization):
            guard
                let credential =
                    authorization.credential
                    as? ASAuthorizationAppleIDCredential,
                let identityData = credential.identityToken,
                let identityToken = String(
                    data: identityData,
                    encoding: .utf8
                ),
                let codeData = credential.authorizationCode,
                let authorizationCode = String(
                    data: codeData,
                    encoding: .utf8
                ),
                let nonce = rawNonce
            else {
                authenticationError =
                    "Apple didn’t return a complete credential. Please try again."
                return
            }
            authenticateWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce
            )
        }
    }

    private func authenticateWithApple(
        identityToken: String,
        authorizationCode: String,
        nonce: String
    ) {
        guard let authClient else {
            accountSession.signInWithApple()
            Task { await onAuthenticated() }
            return
        }
        isAuthenticating = true
        authenticationError = nil
        Task { @MainActor in
            defer { isAuthenticating = false }
            do {
                if try authClient.restoreSession() == nil {
                    _ = try await authClient.bootstrapGuest(
                        installationID: installationID,
                        attestation: nil,
                        applyAccountState: false
                    )
                }
                _ = try await authClient.signInWithApple(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    nonce: nonce,
                    idempotencyKey: UUID().uuidString.lowercased()
                )
                await onAuthenticated()
            } catch {
                authenticationError =
                    "Sign in with Apple didn’t complete. Please try again."
            }
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let alphabet = Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
        )
        var result = ""
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            return UUID().uuidString
        }
        for byte in bytes {
            result.append(alphabet[Int(byte) % alphabet.count])
        }
        return result
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct GoogleSignInControl: View {
    let isEnabled: Bool
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
        .accessibilityIdentifier("welcome.google-sign-in")
    }
}

private struct GoogleSignInButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                LadleTheme.onAccent,
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
