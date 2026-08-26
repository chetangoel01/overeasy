import Foundation
import LadleCore

enum RemoteFailure: Equatable, Sendable {
    case offline
    case serviceUnavailable
    case rateLimited(retryAt: Date)
    case quotaExceeded
    case authenticationExpired
    case invalidResponse
    case unknown

    init(_ error: any Error) {
        guard let apiError = error as? APIError else {
            self = .unknown
            return
        }

        switch apiError {
        case .transport:
            self = .offline
        case .authenticationExpired, .missingAuthentication, .refreshUnavailable:
            self = .authenticationExpired
        case .invalidBaseURL, .invalidResponse, .encoding, .decoding:
            self = .invalidResponse
        case let .remote(remote):
            self = Self(remote)
        }
    }

    private init(_ remote: RemoteErrorDTO) {
        switch remote.code {
        case .providerUnavailable, .internalError:
            self = .serviceUnavailable
        case .quotaExceeded:
            self = .quotaExceeded
        case .rateLimited:
            if case let .rateLimit(retryAt) = remote.details {
                self = .rateLimited(retryAt: retryAt)
            } else {
                self = .invalidResponse
            }
        case .authenticationRequired:
            self = .authenticationExpired
        default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .offline:
            "You're offline"
        case .serviceUnavailable:
            "Service unavailable"
        case .rateLimited:
            "Too many requests"
        case .quotaExceeded:
            "Limit reached"
        case .authenticationExpired:
            "Sign in again"
        case .invalidResponse:
            "Couldn't read the response"
        case .unknown:
            "Something went wrong"
        }
    }

    var message: String {
        switch self {
        case .offline:
            "Your saved recipes are still available. Reconnect to refresh."
        case .serviceUnavailable:
            "The service is temporarily unavailable. Try again in a moment."
        case .rateLimited:
            "This service is busy. Try again when the limit resets."
        case .quotaExceeded:
            "This operation has reached its current quota."
        case .authenticationExpired:
            "Your session expired. Sign in again to continue."
        case .invalidResponse:
            "The service returned data the app couldn't read. Try again."
        case .unknown:
            "The operation couldn't be completed. Try again."
        }
    }

    var retryAt: Date? {
        guard case let .rateLimited(retryAt) = self else { return nil }
        return retryAt
    }

    func canRetry(at date: Date = .now) -> Bool {
        switch self {
        case .offline, .serviceUnavailable, .invalidResponse, .unknown:
            true
        case let .rateLimited(retryAt):
            date >= retryAt
        case .quotaExceeded, .authenticationExpired:
            false
        }
    }
}

struct RemoteFailureReport: Equatable, Sendable {
    let failure: RemoteFailure
    let requestID: UUID?

    init(_ error: any Error) {
        failure = RemoteFailure(error)
        if case let APIError.remote(remote) = error {
            requestID = remote.requestID
        } else {
            requestID = nil
        }
    }
}
