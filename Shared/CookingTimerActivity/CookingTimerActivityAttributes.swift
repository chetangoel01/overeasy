import ActivityKit
import Foundation

/// A running cooking timer, as the Lock Screen and the Dynamic Island show it.
///
/// This file is compiled into both `Ladle` and `LadleTimers`: ActivityKit
/// pairs an activity with its widget by this type, so the two targets have to
/// share the source rather than each keep their own shape of it. It stays out
/// of `LadleCore` because nothing beyond the two iOS targets needs ActivityKit,
/// and it names no `LadleCore` type so the extension does not have to link the
/// package to draw a timer.
struct CookingTimerActivityAttributes: ActivityAttributes {
    /// What changes while the activity is on screen. Three fields on purpose:
    /// the widget derives the countdown, the bar and the finished wording from
    /// them, so an update never restates what can be worked out.
    struct ContentState: Codable, Hashable {
        /// When the running countdown reaches zero, and `nil` while paused —
        /// which is what tells the widget to freeze `remainingSeconds` instead
        /// of counting. The system counts against this date on its own, so the
        /// digits keep moving with the app suspended.
        var endDate: Date?
        /// Authoritative when paused or finished. While running it is the
        /// remaining time as of the update, kept for the paused appearance a
        /// later pause freezes.
        var remainingSeconds: Int
        var isFinished: Bool

        static func running(
            endDate: Date,
            remainingSeconds: Int
        ) -> Self {
            Self(
                endDate: endDate,
                remainingSeconds: remainingSeconds,
                isFinished: false
            )
        }

        static func paused(remainingSeconds: Int) -> Self {
            Self(
                endDate: nil,
                remainingSeconds: remainingSeconds,
                isFinished: false
            )
        }

        static let finished = Self(
            endDate: nil,
            remainingSeconds: 0,
            isFinished: true
        )
    }

    let recipeID: UUID
    let recipeTitle: String
    let stepID: UUID
    /// Zero-based, the way `CookingViewModel.currentStepIndex` and
    /// `RecipeStep.orderIndex` count. Anything shown to a cook adds one.
    let stepIndex: Int
    let timerID: UUID
    let label: String
    let durationSeconds: Int

    /// Where a tap on the activity lands: the cooking screen, at this timer's
    /// step. The shape is the contract with the deep-link handling in #177 —
    /// lowercase UUIDs, and no variation.
    var stepURL: URL? {
        URL(
            string: "overeasy://cooking/"
                + recipeID.uuidString.lowercased()
                + "/steps/"
                + stepID.uuidString.lowercased()
        )
    }
}

/// What a timer is doing, as the Lock Screen has to draw it.
///
/// The app cannot run code when a backgrounded timer reaches zero, so a
/// finish is read from dates rather than told: the system marking the
/// activity stale at the deadline the app set is the finish, and so is a
/// deadline already behind us.
enum CookingTimerAppearance: Equatable {
    /// Counting down to this deadline, which the system advances the digits
    /// and the bar from with nothing of the app's running.
    case running(deadline: Date)
    /// Frozen at the remaining seconds the app last sent.
    case paused(remainingSeconds: Int)
    case finished

    init(
        state: CookingTimerActivityAttributes.ContentState,
        isStale: Bool,
        now: Date = .now
    ) {
        if state.isFinished || isStale {
            self = .finished
        } else if let endDate = state.endDate {
            self = endDate > now ? .running(deadline: endDate) : .finished
        } else {
            self = .paused(remainingSeconds: state.remainingSeconds)
        }
    }
}

/// `m:ss`, and `h:mm:ss` past an hour.
///
/// Shared because the Lock Screen shows a paused timer the app's own frozen
/// digits: two copies of the format would drift, and the cook sees both.
enum CookingTimerClock {
    static func text(for totalSeconds: Int) -> String {
        let clamped = max(totalSeconds, 0)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                seconds
            )
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
