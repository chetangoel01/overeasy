import GoogleSignIn
import UIKit

@MainActor
protocol GoogleSignInProviding: AnyObject {
    func signIn() async throws -> String
    func signOut()
    func disconnect() async
    func handle(_ url: URL) -> Bool
}

enum GoogleSignInProviderError: Error {
    case cancelled
    case missingConfiguration
    case missingPresenter
    case missingIdentityToken
}

@MainActor
final class GoogleSignInProvider: GoogleSignInProviding {
    private var isConfigured = false

    func signIn() async throws -> String {
        try await configureIfNeeded()
        guard let presenter = presentingViewController() else {
            throw GoogleSignInProviderError.missingPresenter
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, any Error>) in
            GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter
            ) { result, error in
                if let error {
                    let value = error as NSError
                    continuation.resume(
                        with: .failure(
                            value.domain == kGIDSignInErrorDomain
                                    && value.code == -5
                                ? GoogleSignInProviderError.cancelled
                                : error
                        )
                    )
                } else if let token = result?.user.idToken?.tokenString {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(
                        throwing: GoogleSignInProviderError
                            .missingIdentityToken
                    )
                }
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    func disconnect() async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            GIDSignIn.sharedInstance.disconnect { _ in
                continuation.resume()
            }
        }
    }

    func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    private func configureIfNeeded() async throws {
        guard !isConfigured else {
            return
        }
        guard
            let clientID = configuredValue("GIDClientID"),
            let serverClientID = configuredValue("GIDServerClientID")
        else {
            throw GoogleSignInProviderError.missingConfiguration
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            GIDSignIn.sharedInstance.configure { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        isConfigured = true
    }

    private func configuredValue(_ key: String) -> String? {
        guard
            let value = Bundle.main.object(
                forInfoDictionaryKey: key
            ) as? String,
            !value.isEmpty,
            !value.contains("$(")
        else {
            return nil
        }
        return value
    }

    private func presentingViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var presenter = root
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        return presenter
    }
}
