import UIKit

@MainActor
protocol IdleTimerControlling: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

@MainActor
final class ApplicationIdleTimerController: IdleTimerControlling {
    var isIdleTimerDisabled: Bool {
        get {
            UIApplication.shared.isIdleTimerDisabled
        }
        set {
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
    }
}

@MainActor
final class ScreenAwakeController {
    private let idleTimer: IdleTimerControlling
    private var previousValue: Bool?

    init(
        idleTimer: IdleTimerControlling =
            ApplicationIdleTimerController()
    ) {
        self.idleTimer = idleTimer
    }

    func beginScope() {
        guard previousValue == nil else {
            return
        }
        previousValue = idleTimer.isIdleTimerDisabled
    }

    func setKeepsScreenAwake(_ keepsScreenAwake: Bool) {
        beginScope()
        idleTimer.isIdleTimerDisabled = keepsScreenAwake
            ? true
            : previousValue ?? false
    }

    func endScope() {
        guard let previousValue else {
            return
        }
        idleTimer.isIdleTimerDisabled = previousValue
        self.previousValue = nil
    }
}
