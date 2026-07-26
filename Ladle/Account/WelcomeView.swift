import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct WelcomeView: View {
    let accountSession: AccountSession
    let authClient: AuthClient?
    let installationID: String
    let onAuthenticated: @MainActor () async -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var rawNonce: String?
    @State private var isAuthenticating = false
    @State private var authenticationError: String?

    var body: some View {
        VStack(spacing: 0) {
            LadleSheetHandle()
                .padding(.top, LadleTheme.Spacing.medium)

            ScrollView {
                VStack(spacing: LadleTheme.Spacing.generous) {
                    welcomeMark

                    VStack(spacing: LadleTheme.Spacing.medium) {
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
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.top, LadleTheme.Spacing.generous)
                .padding(.bottom, LadleTheme.Spacing.regular)
            }
            .scrollIndicators(.hidden)

            accountActions
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.top, LadleTheme.Spacing.compact)
                .padding(.bottom, 22)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: dynamicTypeSize.isAccessibilitySize
                ? .infinity
                : 660
        )
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

    private var welcomeMark: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "frying.pan")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(LadleTheme.paper)
                .frame(width: 88, height: 88)
                .background(
                    LadleTheme.plum,
                    in: RoundedRectangle(
                        cornerRadius: 26,
                        style: .continuous
                    )
                )

            Image(systemName: "link")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LadleTheme.paper)
                .frame(width: 34, height: 34)
                .background(LadleTheme.brick, in: Circle())
                .overlay {
                    Circle()
                        .stroke(LadleTheme.paper, lineWidth: 3)
                }
                .offset(x: 5, y: 5)
        }
        .accessibilityHidden(true)
    }

    private var accountActions: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
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
