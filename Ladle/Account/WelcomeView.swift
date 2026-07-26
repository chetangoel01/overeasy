import AuthenticationServices
import CryptoKit
import GoogleSignIn
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
            LadleTheme.paper
                .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: LadleTheme.Spacing.generous) {
                        welcomeMark
                        welcomeMessage
                        welcomeValues
                        Spacer(minLength: LadleTheme.Spacing.regular)
                        accountActions
                    }
                    .frame(
                        minHeight: proxy.size.height,
                        alignment: .center
                    )
                    .padding(.horizontal, LadleTheme.Spacing.generous)
                    .padding(.vertical, LadleTheme.Spacing.generous)
                }
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.full-screen")
    }

    private var welcomeMark: some View {
        Image("OvereasyMark")
            .resizable()
            .scaledToFit()
            .frame(
                width: dynamicTypeSize.isAccessibilitySize ? 88 : 112,
                height: dynamicTypeSize.isAccessibilitySize ? 88 : 112
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 26,
                    style: .continuous
                )
            )
            .accessibilityLabel("Overeasy app icon")
            .accessibilityIdentifier("welcome.brand-mark")
    }

    private var welcomeMessage: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            Text("Overeasy")
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.brick)

            Text("Recipes, rescued from the scroll.")
                .ladleFont(.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(LadleTheme.ink)

            Text(
                "Turn TikTok, Instagram, and YouTube links into clear recipes made for cooking."
            )
            .ladleFont(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(LadleTheme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomeValues: some View {
        VStack(spacing: 0) {
            WelcomeValue(
                icon: "link",
                text: "Paste a link or share from the scroll."
            )
            Divider()
                .overlay(LadleTheme.ink.opacity(0.08))
                .padding(.leading, 46)
            WelcomeValue(
                icon: "checklist",
                text: "Cook from clear steps with timers ready."
            )
        }
    }

    private var accountActions: some View {
        VStack(spacing: LadleTheme.Spacing.compact) {
            SignInWithAppleButton(.continue) { request in
                let nonce = Self.randomNonce()
                rawNonce = nonce
                request.requestedScopes = [.email, .fullName]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                handleAppleCompletion(result)
            }
            .signInWithAppleButtonStyle(.black)
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
            .frame(maxWidth: .infinity)
            .frame(height: 52)

            Button {
                authenticateAsGuest()
            } label: {
                Text("Try as a guest")
            }
            .buttonStyle(
                LadlePrimaryButtonStyle(isProminent: false)
            )
            .disabled(isAuthenticating)

            Text(
                "Guests can save up to 10 recipes. Sign in later without losing them."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.mutedInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, LadleTheme.Spacing.compact)

            if isAuthenticating {
                ProgressView("Setting up Overeasy")
                    .ladleFont(.metadata)
                    .tint(LadleTheme.brick)
                    .foregroundStyle(LadleTheme.mutedInk)
            }

            if let authenticationError {
                Text(authenticationError)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.brick)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

private struct GoogleSignInControl: UIViewRepresentable {
    let isEnabled: Bool
    let action: @MainActor () -> Void

    func makeUIView(context: Context) -> GIDSignInButton {
        let button = GIDSignInButton()
        button.style = .wide
        button.colorScheme = .light
        button.accessibilityIdentifier = "welcome.google-sign-in"
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.activate),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ button: GIDSignInButton, context: Context) {
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func activate() {
            action()
        }
    }
}

private struct WelcomeValue: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: LadleTheme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LadleTheme.brick)
                .frame(width: 34, height: 34)
                .background(LadleTheme.ube, in: Circle())

            Text(text)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, LadleTheme.Spacing.compact)
        .accessibilityElement(children: .combine)
    }
}
