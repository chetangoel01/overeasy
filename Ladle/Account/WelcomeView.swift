import AuthenticationServices
import CryptoKit
import Security
import SwiftUI
import UIKit

private enum WelcomeStage: Int, CaseIterable {
    case brand
    case importing
    case share
    case start
}

struct WelcomeView: View {
    let accountSession: AccountSession
    let authClient: AuthClient?
    let installationID: String
    let onAuthenticated: @MainActor () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: WelcomeStage = .brand
    @State private var rawNonce: String?
    @State private var appleAuthorizationDelegate:
        AppleAuthorizationDelegate?
    @State private var isAuthenticating = false
    @State private var authenticationError: String?

    private static let shareTrialURL = URL(
        string:
            "https://www.tiktok.com/@mishkamakesfood/video/7628226554589482271"
    )!

    var body: some View {
        VStack(spacing: 0) {
            LadleSheetHandle()
                .padding(.top, 10)

            TabView(selection: $stage) {
                ForEach(WelcomeStage.allCases, id: \.self) { candidate in
                    ScrollView {
                        pageContent(candidate)
                            .padding(
                                .horizontal,
                                LadleTheme.Spacing.generous
                            )
                            .padding(.top, 18)
                            .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    .tag(candidate)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            stageDots
                .padding(.vertical, 10)

            footer
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.bottom, 22)
        }
        .frame(maxHeight: 580)
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

    @ViewBuilder
    private func pageContent(_ stage: WelcomeStage) -> some View {
        switch stage {
        case .brand:
            WelcomePage(
                icon: "frying.pan",
                title: "Overeasy",
                message:
                    "Recipes, rescued from the scroll. Share a recipe video once and get something you can actually cook."
            )
        case .importing:
            WelcomePage(
                icon: "link.badge.plus",
                title: "Paste any\nrecipe link",
                message:
                    "Drop in a TikTok, Instagram, or YouTube link and Overeasy cracks it into clear ingredients, steps, and estimated nutrition."
            ) {
                WelcomeFeature(
                    icon: "text.badge.checkmark",
                    text: "Structured ingredients and steps"
                )
                WelcomeFeature(
                    icon: "timer",
                    text: "Detected timers and hands-free cooking"
                )
                WelcomeFeature(
                    icon: "chart.bar",
                    text: "Estimated nutrition, clearly labeled"
                )
            }
        case .share:
            WelcomePage(
                icon: "square.and.arrow.up",
                title: "Save without\nleaving the scroll",
                message:
                    "Found a recipe mid-scroll? Tap Share and pick “Add to Overeasy”. The recipe is waiting the next time you open the app."
            ) {
                ShareLink(item: Self.shareTrialURL) {
                    Text("Try it with a sample video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    LadlePrimaryButtonStyle(isProminent: false)
                )
                .accessibilityIdentifier("welcome.share-trial")

                Text(
                    "Choose “Add to Overeasy” in the share sheet — it imports once you’re in."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.55))
                .multilineTextAlignment(.center)
            }
        case .start:
            WelcomePage(
                icon: "flame",
                title: "Get cooking",
                message:
                    "Keep your saves in one calm place, synced to your account. Start however you like."
            )
        }
    }

    private var stageDots: some View {
        HStack(spacing: 7) {
            ForEach(WelcomeStage.allCases, id: \.self) { candidate in
                Circle()
                    .fill(
                        candidate == stage
                            ? LadleTheme.paprika
                            : LadleTheme.ink.opacity(0.18)
                    )
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var footer: some View {
        if stage == .start {
            accountActions
        } else {
            VStack(spacing: 11) {
                Button {
                    advance()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(LadlePrimaryButtonStyle())
                .accessibilityIdentifier("welcome.continue")

                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        stage = .start
                    }
                } label: {
                    Text("Skip the tour")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink.opacity(0.55))
                        .frame(minHeight: 32)
                }
            }
        }
    }

    private func advance() {
        guard let next = WelcomeStage(rawValue: stage.rawValue + 1) else {
            return
        }
        withAnimation(reduceMotion ? nil : .default) {
            stage = next
        }
    }

    private var accountActions: some View {
        VStack(spacing: 11) {
            SignInWithAppleButton(.signIn) { request in
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
                startAppleAuthorization()
            } label: {
                Text("Create a free account")
            }
            .buttonStyle(
                LadlePrimaryButtonStyle(isProminent: false)
            )
            .disabled(isAuthenticating)

            Button {
                authenticateAsGuest()
            } label: {
                Text("Continue as a guest")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                    .frame(minHeight: 38)
            }
            .disabled(isAuthenticating)

            Text("Guests can save up to 10 recipes.")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.55))

            if let authenticationError {
                Text(authenticationError)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.paprika)
                    .multilineTextAlignment(.center)
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
                    "Couldn’t connect to Overeasy. Please try again."
            }
        }
    }

    private func handleAppleCompletion(
        _ result: Result<ASAuthorization, any Error>
    ) {
        appleAuthorizationDelegate = nil
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
                    "Apple didn’t return a complete credential."
                return
            }
            authenticateWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce
            )
        }
    }

    private func startAppleAuthorization() {
        let nonce = Self.randomNonce()
        rawNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email, .fullName]
        request.nonce = Self.sha256(nonce)
        let delegate = AppleAuthorizationDelegate { result in
            handleAppleCompletion(result)
        }
        appleAuthorizationDelegate = delegate
        let controller = ASAuthorizationController(
            authorizationRequests: [request]
        )
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        controller.performRequests()
    }

    private func authenticateWithApple(
        identityToken: String,
        authorizationCode: String,
        nonce: String
    ) {
        guard let authClient else {
            accountSession.signInWithApple()
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

private struct WelcomePage<Extra: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let extra: Extra

    init(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.extra = extra()
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 50, height: 50)
                .background(LadleTheme.review, in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(title)
                    .ladleFont(.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LadleTheme.ink)

                Text(message)
                    .ladleFont(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LadleTheme.ink.opacity(0.67))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                extra
            }
        }
    }
}

@MainActor
private final class AppleAuthorizationDelegate:
    NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private let completion:
        (Result<ASAuthorization, any Error>) -> Void

    init(
        completion:
            @escaping (Result<ASAuthorization, any Error>) -> Void
    ) {
        self.completion = completion
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        completion(.success(authorization))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        completion(.failure(error))
    }

    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            return keyWindow
        }
        guard let scene = scenes.first else {
            preconditionFailure("Apple sign-in requires an active window scene")
        }
        return ASPresentationAnchor(windowScene: scene)
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
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
