// ActivityKit's `Activity` is not annotated `Sendable`, although `update` and
// `end` are meant to be called from anywhere and this presenter only ever
// touches one from the main actor. Without this, every hand-off into the task
// that performs the update is an error rather than the no-op it is.
@preconcurrency import ActivityKit
import Foundation
import LadleCore
import os

/// Mirrors a cooking timer onto the Lock Screen and the Dynamic Island.
///
/// Every method is best-effort and nothing returns a result: a cook whose
/// phone refuses Live Activities still gets the timer, the alert and the
/// screen it has always had. Nothing in the cooking session may wait on, or
/// branch on, what happens here.
@MainActor
protocol TimerActivityPresenting: AnyObject {
    /// Start, or resume — a timer that was paused keeps the activity it
    /// already has, moved to the new deadline.
    func start(
        _ timer: RecipeTimer,
        in recipe: Recipe,
        stepID: UUID,
        stepIndex: Int,
        endDate: Date
    )

    /// Takes over the activities a previous launch left behind: one whose
    /// timer the restored session still has running is adopted, so the next
    /// `start` moves it rather than duplicating it, and every other is ended.
    ///
    /// The process that requested them is gone, so without this nothing could
    /// move or end them again.
    func adoptActivities(forRunningTimers timerIDs: Set<UUID>)
    func pause(timerID: UUID, remainingSeconds: Int)
    /// A timer that reached zero with the app in front. A finish stays on the
    /// Lock Screen briefly rather than vanishing as the digits hit zero.
    func finish(timerID: UUID)
    /// Acknowledged, reset, or otherwise done with: off the Lock Screen now.
    func end(timerID: UUID)
    func endAll()
    /// The foreground pass: a timer whose deadline passed while the app was
    /// away has already drawn its finish from the stale date, and the cook is
    /// now holding the phone.
    func endFinished(now: Date)
}

extension CookingTimerActivityAttributes {
    /// The fixed half of an activity, as a session already holds it.
    init(
        timer: RecipeTimer,
        recipe: Recipe,
        stepID: UUID,
        stepIndex: Int
    ) {
        self.init(
            recipeID: recipe.id,
            recipeTitle: recipe.title,
            stepID: stepID,
            stepIndex: stepIndex,
            timerID: timer.id,
            label: timer.label,
            durationSeconds: timer.durationSeconds
        )
    }
}

@MainActor
final class LiveActivityTimerPresenter: TimerActivityPresenting {
    /// How long a finished timer stays on the Lock Screen. Long enough for a
    /// cook to walk back to the phone, short enough not to outlive the dish.
    static let finishedLinger: TimeInterval = 5 * 60

    private static let log = Logger(
        subsystem: "com.ladle.ios",
        category: "cooking-timer-activity"
    )

    private var activities: [UUID: Activity<CookingTimerActivityAttributes>] =
        [:]
    private var hasLoggedFailure = false

    func start(
        _ timer: RecipeTimer,
        in recipe: Recipe,
        stepID: UUID,
        stepIndex: Int,
        endDate: Date
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        // The stale date is the deadline: the app cannot run code when a
        // background timer reaches zero, so the system marking the activity
        // stale is what draws the finish on time.
        let content = ActivityContent<
            CookingTimerActivityAttributes.ContentState
        >(
            state: .running(
                endDate: endDate,
                remainingSeconds: Self.secondsUntil(endDate)
            ),
            staleDate: endDate
        )
        if let activity = activities[timer.id] {
            update(activity, to: content)
            return
        }
        do {
            activities[timer.id] = try Activity.request(
                attributes: CookingTimerActivityAttributes(
                    timer: timer,
                    recipe: recipe,
                    stepID: stepID,
                    stepIndex: stepIndex
                ),
                content: content,
                pushType: nil
            )
        } catch {
            logFailure(error)
        }
    }

    func pause(timerID: UUID, remainingSeconds: Int) {
        guard let activity = activities[timerID] else {
            return
        }
        update(
            activity,
            to: ActivityContent(
                state: .paused(remainingSeconds: remainingSeconds),
                staleDate: nil
            )
        )
    }

    func finish(timerID: UUID) {
        guard let activity = activities[timerID] else {
            return
        }
        let dismissal = Date.now.addingTimeInterval(Self.finishedLinger)
        // The activity stays in the dictionary while it lingers: a cook who
        // acknowledges or resets the timer inside those five minutes ends
        // this same activity at once.
        Task {
            await activity.end(
                ActivityContent(state: .finished, staleDate: nil),
                dismissalPolicy: .after(dismissal)
            )
        }
    }

    func end(timerID: UUID) {
        guard let activity = activities.removeValue(forKey: timerID) else {
            return
        }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func endAll() {
        for timerID in activities.keys {
            end(timerID: timerID)
        }
    }

    func endFinished(now: Date) {
        for (timerID, activity) in activities {
            // A finish already lingering has no deadline left to read, and is
            // meant to stay for its five minutes.
            guard let endDate = activity.content.state.endDate,
                  endDate <= now else {
                continue
            }
            end(timerID: timerID)
        }
    }

    func adoptActivities(forRunningTimers timerIDs: Set<UUID>) {
        for activity in Activity<CookingTimerActivityAttributes>.activities {
            let timerID = activity.attributes.timerID
            if timerIDs.contains(timerID) {
                // Adopted rather than re-requested: the restored session
                // calls `start` next, which moves this one to the deadline
                // it came back with instead of leaving a stale twin behind.
                activities[timerID] = activity
            } else {
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    private func update(
        _ activity: Activity<CookingTimerActivityAttributes>,
        to content: ActivityContent<
            CookingTimerActivityAttributes.ContentState
        >
    ) {
        Task {
            await activity.update(content)
        }
    }

    private static func secondsUntil(_ endDate: Date) -> Int {
        max(Int(endDate.timeIntervalSinceNow.rounded(.up)), 0)
    }

    /// Once per session. A phone that refuses activities refuses every one of
    /// them, and a timer log per refusal buries everything else.
    private func logFailure(_ error: any Error) {
        guard !hasLoggedFailure else {
            return
        }
        hasLoggedFailure = true
        Self.log.error(
            "Live Activity unavailable: \(error.localizedDescription)"
        )
    }
}
