import Foundation
import Observation

@MainActor
@Observable
final class SyncStatus {
    enum State: Equatable, Sendable {
        case idle
        case syncing
        case current
        case failed(RemoteFailureReport)
    }

    private(set) var state: State = .idle
    private(set) var lastSuccessfulSync: Date?

    var failure: RemoteFailure? {
        guard case let .failed(report) = state else { return nil }
        return report.failure
    }

    var retryAt: Date? {
        failure?.retryAt
    }

    var shortLabel: String {
        state.shortLabel
    }

    func begin() {
        state = .syncing
    }

    func succeed(at date: Date = .now) {
        lastSuccessfulSync = date
        state = .current
    }

    func fail(_ error: any Error) {
        state = .failed(RemoteFailureReport(error))
    }

    func cancel() {
        guard state == .syncing else { return }
        state = lastSuccessfulSync == nil ? .idle : .current
    }

    func reset() {
        state = .idle
        lastSuccessfulSync = nil
    }
}

extension SyncStatus.State {
    var shortLabel: String {
        switch self {
        case .idle:
            "Waiting"
        case .syncing:
            "Syncing"
        case .current:
            "Up to date"
        case let .failed(report):
            switch report.failure {
            case .offline:
                "Offline"
            case .serviceUnavailable:
                "Unavailable"
            case .rateLimited:
                "Try later"
            case .quotaExceeded:
                "Limit reached"
            case .authenticationExpired:
                "Sign in again"
            case .invalidResponse, .unknown:
                "Needs attention"
            }
        }
    }
}
