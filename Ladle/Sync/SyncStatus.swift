import Foundation
import Observation

@MainActor
@Observable
final class SyncStatus {
    enum State: Equatable, Sendable {
        case idle
        case syncing
        case current
        case conflict(count: Int)
        case failed(RemoteFailureReport)
    }

    private(set) var state: State = .idle
    private(set) var lastSuccessfulSync: Date?
    private var unresolvedConflictCount = 0

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
        unresolvedConflictCount = 0
        state = .current
    }

    func requireConflictResolution(count: Int) {
        precondition(count > 0)
        unresolvedConflictCount = count
        state = .conflict(count: count)
    }

    func fail(_ error: any Error) {
        state = .failed(RemoteFailureReport(error))
    }

    func cancel() {
        guard state == .syncing else { return }
        if unresolvedConflictCount > 0 {
            state = .conflict(count: unresolvedConflictCount)
        } else {
            state = lastSuccessfulSync == nil ? .idle : .current
        }
    }

    func reset() {
        state = .idle
        lastSuccessfulSync = nil
        unresolvedConflictCount = 0
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
        case let .conflict(count):
            count == 1 ? "Review 1 change" : "Review \(count) changes"
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
