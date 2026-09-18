import Foundation
import LadleCore
import Observation

/// A cooking session as a relaunch has to find it again.
///
/// The recipe is a reference, not a copy: it is fetched from the repository
/// at launch, so a session restored after an edit cooks the current recipe.
struct CookingSessionSnapshot: Codable, Equatable {
    let recipeID: UUID
    /// The serving count the session was started at. Both halves or
    /// neither: a session started from Watch has no scaling at all.
    let baseServings: Decimal?
    let servings: Decimal?
    let session: CookingSession
    let timers: [CookingTimerSnapshot]

    var scaling: RecipeScaling? {
        guard let baseServings, let servings else {
            return nil
        }
        var scaling = RecipeScaling(baseServings: baseServings)
        scaling.setServings(servings)
        return scaling
    }
}

/// A start that would end another recipe's running timers, held until the
/// cook says so.
struct CookingReplacement: Identifiable {
    let id = UUID()
    /// The session in the way — the one whose timers the dialog names.
    let activeRecipeTitle: String

    fileprivate let recipe: Recipe
    fileprivate let scaling: RecipeScaling?
    fileprivate let stepID: UUID?
}

/// The one cooking session the app has, held by the runtime rather than by
/// whichever screen started it.
///
/// Before this, the session was `@State` on the recipe page and on Watch, so
/// leaving the cooking screen deallocated it and cancelled every pending
/// timer alert — a cook who stepped out to another tab lost the timer
/// without being told (#177). The session now outlives the screen: the
/// screen is a cover bound to `presented`, and `active` is what is actually
/// cooking.
@MainActor
@Observable
final class CookingSessionStore {
    static let snapshotKey = "cooking.active-session"

    /// The session that is cooking, whether or not anything is showing it.
    private(set) var active: CookingViewModel?

    /// The session the full-screen cover is showing. Dismissing the cover
    /// clears this and leaves `active` alone — that is the whole point.
    var presented: CookingViewModel?

    private(set) var pendingReplacement: CookingReplacement?

    @ObservationIgnored
    private let snapshots: any PreferenceStoring

    @ObservationIgnored
    private let findRecipe: @MainActor (UUID) -> Recipe?

    @ObservationIgnored
    private let makeViewModel:
        @MainActor (Recipe, RecipeScaling?) -> CookingViewModel

    @ObservationIgnored
    private let alarm: TimerAlarm

    @ObservationIgnored
    private let clock: CookingClock

    @ObservationIgnored
    private var isForeground = true

    @ObservationIgnored
    private var alarmTask: Task<Void, Never>?

    init(
        snapshots: any PreferenceStoring = UserDefaults.standard,
        findRecipe: @escaping @MainActor (UUID) -> Recipe? = { _ in nil },
        makeViewModel: @escaping @MainActor (
            Recipe,
            RecipeScaling?
        ) -> CookingViewModel = {
            CookingViewModel(recipe: $0, scaling: $1)
        },
        alarm: TimerAlarm = TimerAlarm(),
        clock: CookingClock = SystemCookingClock()
    ) {
        self.snapshots = snapshots
        self.findRecipe = findRecipe
        self.makeViewModel = makeViewModel
        self.alarm = alarm
        self.clock = clock
    }

    /// Starts cooking, resumes the session already running this recipe, or
    /// asks first when another recipe's timers would have to end.
    ///
    /// The question is only worth putting when something is still counting
    /// down: a session nobody is timing is replaced without a word.
    @discardableResult
    func start(
        recipe: Recipe,
        scaling: RecipeScaling? = nil,
        stepID: UUID? = nil
    ) -> CookingReplacement? {
        if let active, active.recipe.id == recipe.id {
            if let stepID {
                active.selectStep(id: stepID)
            }
            presented = active
            return nil
        }
        if let active, active.hasRunningTimer {
            let replacement = CookingReplacement(
                activeRecipeTitle: active.recipe.title,
                recipe: recipe,
                scaling: scaling,
                stepID: stepID
            )
            pendingReplacement = replacement
            return replacement
        }
        replace(with: recipe, scaling: scaling, stepID: stepID)
        return nil
    }

    func confirmReplacement() {
        guard let replacement = pendingReplacement else {
            return
        }
        pendingReplacement = nil
        replace(
            with: replacement.recipe,
            scaling: replacement.scaling,
            stepID: replacement.stepID
        )
    }

    func cancelReplacement() {
        pendingReplacement = nil
    }

    /// Brings the running session back on screen.
    func resume() {
        presented = active
    }

    /// Ends the session: its alerts are cancelled, its snapshot is dropped,
    /// and anything showing it is dismissed.
    func end() {
        stopAlarm()
        alarm.reset()
        active?.endSession()
        active = nil
        presented = nil
        snapshots.removeObject(forKey: Self.snapshotKey)
    }

    /// Takes a session left by a previous launch, if the recipe is still
    /// there. Nothing is presented: the cook decides when to look at it.
    func restore() {
        guard active == nil else {
            return
        }
        guard let snapshot = storedSnapshot(),
              let recipe = findRecipe(snapshot.recipeID) else {
            snapshots.removeObject(forKey: Self.snapshotKey)
            return
        }
        let viewModel = adopt(
            makeViewModel(recipe, snapshot.scaling)
        )
        viewModel.restore(snapshot)
        active = viewModel
        // A timer that ran out while the app was gone already delivered its
        // notification. That was its alarm; coming back is not a second one.
        alarm.suppress(viewModel.finishedTimerIDs)
        startAlarm()
    }

    /// Whether this recipe is the one being cooked, which is what turns
    /// "Start Cooking" into "Resume cooking".
    func isCooking(_ recipeID: UUID) -> Bool {
        active?.recipe.id == recipeID
    }

    /// Follows a tapped timer alert or an `overeasy://` link back to the
    /// step that set the timer, starting a session if there is none.
    func open(_ destination: NotificationDestination) {
        guard case let .cookingStep(recipeID, stepID, _) = destination else {
            return
        }
        if let active, active.recipe.id == recipeID {
            start(recipe: active.recipe, stepID: stepID)
        } else if let recipe = findRecipe(recipeID) {
            start(recipe: recipe, stepID: stepID)
        }
    }

    /// The alarm is a foreground affair. In the background the notification
    /// is the alarm, so the loop stops and what finished while away is
    /// marked as already answered when the app comes back.
    func setForeground(_ isForeground: Bool) {
        guard self.isForeground != isForeground else {
            return
        }
        self.isForeground = isForeground
        if isForeground {
            alarm.suppress(active?.finishedTimerIDs ?? [])
            startAlarm()
        } else {
            stopAlarm()
            persist()
        }
    }

    /// One pass of the alarm, exposed so a test can drive the cadence
    /// without waiting on the loop's real-time sleep.
    func soundAlarmIfNeeded() {
        guard let active, isForeground else {
            return
        }
        alarm.tick(finishedTimerIDs: active.finishedTimerIDs, at: clock.now)
    }

    private func replace(
        with recipe: Recipe,
        scaling: RecipeScaling?,
        stepID: UUID?
    ) {
        end()
        let viewModel = adopt(makeViewModel(recipe, scaling))
        active = viewModel
        if let stepID {
            viewModel.selectStep(id: stepID)
        }
        persist()
        presented = viewModel
        startAlarm()
    }

    private func adopt(
        _ viewModel: CookingViewModel
    ) -> CookingViewModel {
        viewModel.sessionDidChange = { [weak self] in
            self?.persist()
        }
        return viewModel
    }

    private func persist() {
        guard let active,
              let data = try? JSONEncoder().encode(active.snapshot),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        snapshots.set(text, forKey: Self.snapshotKey)
    }

    private func storedSnapshot() -> CookingSessionSnapshot? {
        guard let text = snapshots.string(forKey: Self.snapshotKey),
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(
            CookingSessionSnapshot.self,
            from: data
        )
    }

    /// A one-second heartbeat, because a timer's completion is derived from
    /// the clock rather than stored: nothing publishes the moment it runs
    /// out, so the alarm has to look.
    private func startAlarm() {
        guard alarmTask == nil, active != nil, isForeground else {
            return
        }
        alarmTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                soundAlarmIfNeeded()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopAlarm() {
        alarmTask?.cancel()
        alarmTask = nil
    }
}
