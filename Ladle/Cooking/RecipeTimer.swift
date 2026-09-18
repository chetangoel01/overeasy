import Foundation
import LadleCore
import SwiftUI
import UserNotifications

@MainActor
protocol CookingClock {
    var now: Date { get }
}

@MainActor
struct SystemCookingClock: CookingClock {
    var now: Date {
        .now
    }
}

/// Everything a finished timer's alert has to say, and everything a tap on
/// it has to carry back: the alert leads to the step that set the timer, so
/// the step travels with it rather than being looked up when the tap lands.
struct TimerNotification: Equatable, Sendable {
    let timerID: UUID
    let label: String
    let durationSeconds: Int
    let recipeID: UUID
    let recipeTitle: String
    let stepID: UUID
    /// The step's place in the method, numbered from 1 as the cook reads it.
    let stepNumber: Int
}

@MainActor
protocol TimerNotificationScheduling: AnyObject {
    func schedule(_ notification: TimerNotification) async

    func cancel(timerID: UUID)
}

@MainActor
protocol CookingNotificationCenter {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: CookingNotificationCenter {}

@MainActor
final class LocalTimerNotificationScheduler:
    TimerNotificationScheduling
{
    private let center: any CookingNotificationCenter
    private let now: () -> Date
    /// The newest scheduling attempt per timer. A request identifier cannot
    /// serve as this token any more — it is derived from the timer id so a
    /// relaunched app can still cancel what a previous launch scheduled —
    /// so supersession is tracked separately.
    private var tokens: [UUID: UUID] = [:]

    /// The sound each request carries. Resolved per request rather than
    /// once, because `TimerTone` may only manage its copy for notifications
    /// on a later call than the first.
    private let sound: () -> UNNotificationSound

    init(
        center: any CookingNotificationCenter = UNUserNotificationCenter.current(),
        now: @escaping () -> Date = Date.init,
        sound: @escaping () -> UNNotificationSound = {
            TimerTone.notificationSound()
        }
    ) {
        self.center = center
        self.now = now
        self.sound = sound
    }

    func schedule(_ notification: TimerNotification) async {
        guard notification.durationSeconds > 0 else {
            return
        }
        let timerID = notification.timerID
        let deadline = now().addingTimeInterval(
            TimeInterval(notification.durationSeconds)
        )
        let requestID = Self.identifier(for: timerID)
        let token = UUID()
        tokens[timerID] = token

        do {
            let isAuthorized = try await center.requestAuthorization(
                options: [.alert, .sound]
            )
            guard isAuthorized else {
                clearToken(token, for: timerID)
                return
            }
            guard tokens[timerID] == token else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "\(notification.label) is ready"
            content.body =
                "\(notification.recipeTitle), step \(notification.stepNumber)."
            content.sound = sound()
            // A timer the cook is waiting on outranks a Focus, which is
            // what the time-sensitive entitlement buys.
            content.interruptionLevel = .timeSensitive
            content.userInfo = [
                "recipeID": notification.recipeID.uuidString,
                "stepID": notification.stepID.uuidString,
                "timerID": timerID.uuidString,
            ]

            // Permission may take longer than the timer itself. Keep the
            // original deadline and deliver immediately if it has passed.
            let remaining = deadline.timeIntervalSince(now())
            let request = UNNotificationRequest(
                identifier: requestID,
                content: content,
                trigger: remaining > 0 ? UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, remaining),
                    repeats: false
                ) : nil
            )
            try await center.add(request)
            if tokens[timerID] != token {
                center.removePendingNotificationRequests(
                    withIdentifiers: [requestID]
                )
            }
        } catch {
            clearToken(token, for: timerID)
            // The in-app timer remains usable when notifications are denied.
        }
    }

    func cancel(timerID: UUID) {
        tokens[timerID] = nil
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(for: timerID)]
        )
    }

    private func clearToken(_ token: UUID, for timerID: UUID) {
        if tokens[timerID] == token {
            tokens[timerID] = nil
        }
    }

    /// Derived from the timer alone, so the request a previous launch left
    /// pending is the one this launch cancels when the cook resets a
    /// restored timer. Re-adding the same identifier replaces the pending
    /// request, which is what rescheduling wants.
    private static func identifier(for timerID: UUID) -> String {
        "ladle.cooking-timer.\(timerID.uuidString)"
    }
}

enum RecipeTimerPhase: String, Codable, Equatable {
    case idle
    case running
    case paused
    case finished
}

/// A timer as a relaunch has to find it again: its phase and the countdown
/// as an amount plus the moment it was measured from, never a remaining
/// number alone — that would restore a timer that had been paused for an
/// hour and one that is still running identically.
struct CookingTimerSnapshot: Codable, Equatable {
    let timerID: UUID
    let phase: RecipeTimerPhase
    let remainingAtReference: TimeInterval
    let referenceDate: Date?
}

struct RecipeTimer: Equatable, Identifiable {
    let detectedTimer: DetectedTimer
    private(set) var phase: RecipeTimerPhase = .idle

    private var remainingAtReference: TimeInterval
    private var referenceDate: Date?

    init(_ detectedTimer: DetectedTimer) {
        self.detectedTimer = detectedTimer
        remainingAtReference = TimeInterval(
            max(detectedTimer.durationSeconds, 0)
        )
    }

    /// Restores a snapshotted timer. A countdown whose deadline passed while
    /// the app was gone comes back finished: its alert has already fired, and
    /// the cook is owed the finished card, not a timer at 0:00 still running.
    init(
        _ detectedTimer: DetectedTimer,
        snapshot: CookingTimerSnapshot,
        at date: Date
    ) {
        self.detectedTimer = detectedTimer
        phase = snapshot.phase
        remainingAtReference = snapshot.remainingAtReference
        referenceDate = snapshot.referenceDate
        if phase == .running, remainingSeconds(at: date) == 0 {
            remainingAtReference = 0
            referenceDate = nil
            phase = .finished
        }
    }

    var snapshot: CookingTimerSnapshot {
        CookingTimerSnapshot(
            timerID: id,
            phase: phase,
            remainingAtReference: remainingAtReference,
            referenceDate: referenceDate
        )
    }

    var id: UUID {
        detectedTimer.id
    }

    var label: String {
        detectedTimer.label
    }

    var durationSeconds: Int {
        detectedTimer.durationSeconds
    }

    func remainingSeconds(at date: Date) -> Int {
        let seconds: TimeInterval
        if phase == .running, let referenceDate {
            seconds = remainingAtReference
                - date.timeIntervalSince(referenceDate)
        } else {
            seconds = remainingAtReference
        }
        return max(Int(ceil(seconds)), 0)
    }

    func phase(at date: Date) -> RecipeTimerPhase {
        if phase == .running, remainingSeconds(at: date) == 0 {
            return .finished
        }
        return phase
    }

    @discardableResult
    mutating func start(at date: Date) -> Bool {
        guard phase != .running,
              remainingSeconds(at: date) > 0 else {
            return false
        }
        referenceDate = date
        phase = .running
        return true
    }

    mutating func pause(at date: Date) {
        guard phase == .running else {
            return
        }
        remainingAtReference = TimeInterval(
            remainingSeconds(at: date)
        )
        referenceDate = nil
        phase = remainingAtReference > 0 ? .paused : .finished
    }

    mutating func reset() {
        remainingAtReference = TimeInterval(
            max(detectedTimer.durationSeconds, 0)
        )
        referenceDate = nil
        phase = .idle
    }
}

struct RecipeTimerButton: View {
    @Environment(\.ladleAccent) private var accent

    @Bindable var viewModel: CookingViewModel
    let detectedTimer: DetectedTimer
    var onDark = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: LadleTheme.Layout.rowGap) {
                Button {
                    toggleTimer()
                } label: {
                    HStack(spacing: LadleTheme.Layout.iconGap) {
                        timerRing
                        VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                            Text(actionTitle)
                                .ladleFont(.metadata)
                            Text(clockText)
                                .ladleScaledFont(
                                    size: 19,
                                    relativeTo: .body,
                                    weight: .semibold,
                                    design: .monospaced
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(cardForeground)
                    .padding(.horizontal, LadleTheme.Layout.cardPadding)
                    .frame(minHeight: onDark ? 68 : 58)
                    .background(
                        cardBackground,
                        in: RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(LadlePressButtonStyle())
                .accessibilityLabel(accessibilityTitle)

                if phase != .idle {
                    Button {
                        viewModel.resetTimer(id: detectedTimer.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: LadleTheme.IconSize.medium, weight: .semibold))
                            .foregroundStyle(
                                onDark
                                    ? LadleTheme.Label.onAccent
                                    : accent.label
                            )
                            .frame(
                                width: LadleTheme.Control.field,
                                height: LadleTheme.Control.field
                            )
                            .background(
                                onDark
                                    ? LadleTheme.Label.onAccent.opacity(0.12)
                                    : LadleTheme.Surface.raised,
                                in: Circle()
                            )
                    }
                    .buttonStyle(LadlePressButtonStyle())
                    .accessibilityLabel(
                        "Reset \(detectedTimer.label) timer"
                    )
                }
            }
            // Inside the TimelineView content, so each per-second refresh
            // re-reads the trigger. Completion is purely time-derived —
            // the stored phase never mutates to .finished — and this
            // refresh is the only place the .running -> .finished
            // transition is ever observed; attached outside, the finish
            // haptic could never fire.
            .sensoryFeedback(
                .impact(weight: .medium, intensity: 0.8),
                trigger: phase
            ) { oldPhase, newPhase in
                LadleFeedbackPolicy.timerFeedback(
                    from: oldPhase,
                    to: newPhase
                ) == .started
            }
            .sensoryFeedback(.selection, trigger: phase) {
                oldPhase,
                newPhase in
                LadleFeedbackPolicy.timerFeedback(
                    from: oldPhase,
                    to: newPhase
                ) == .paused
            }
            .sensoryFeedback(.success, trigger: phase) {
                oldPhase,
                newPhase in
                LadleFeedbackPolicy.timerFeedback(
                    from: oldPhase,
                    to: newPhase
                ) == .finished
            }
            // Same reason as the haptics above: this refresh is the only
            // place the app ever observes a countdown reaching zero, so the
            // Lock Screen's finish is reported from inside it. A timer that
            // finishes on a step the cook has left is not seen here at all —
            // the activity's stale date draws that one.
            .onChange(of: phase) { _, newPhase in
                if newPhase == .finished {
                    viewModel.timerDidFinish(id: detectedTimer.id)
                }
            }
        }
    }

    private var phase: RecipeTimerPhase {
        viewModel.timerPhase(for: detectedTimer.id) ?? .idle
    }

    private var remainingSeconds: Int {
        viewModel.remainingSeconds(for: detectedTimer.id)
            ?? detectedTimer.durationSeconds
    }

    private var cardBackground: Color {
        if phase == .finished {
            LadleTheme.Intent.success
        } else {
            onDark ? LadleTheme.Label.onAccent : LadleTheme.Surface.steel
        }
    }

    // The non-finished onDark card is fixed porcelain, so its content needs
    // a fixed dark foreground rather than the adaptive ink.
    private var cardForeground: Color {
        if onDark, phase != .finished {
            LadleTheme.Label.onFixedPale
        } else {
            LadleTheme.Label.primary
        }
    }

    /// The timer ring drains as time runs out.
    private var timerRing: some View {
        ZStack {
            Circle()
                .stroke(cardForeground.opacity(0.2), lineWidth: 3)

            Circle()
                .trim(from: 0, to: remainingFraction)
                .stroke(
                    phase == .finished
                        ? cardForeground
                        : accent.intent,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: timerIcon)
                .font(.system(size: LadleTheme.IconSize.small, weight: .bold))
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private var remainingFraction: CGFloat {
        guard detectedTimer.durationSeconds > 0 else {
            return 0
        }
        return CGFloat(remainingSeconds)
            / CGFloat(detectedTimer.durationSeconds)
    }

    private var clockText: String {
        Self.clockText(for: remainingSeconds)
    }

    private var actionTitle: String {
        switch phase {
        case .idle:
            "Start \(detectedTimer.label)"
        case .running:
            "Pause \(detectedTimer.label)"
        case .paused:
            "Resume \(detectedTimer.label)"
        case .finished:
            "\(detectedTimer.label) finished"
        }
    }

    private var timerIcon: String {
        switch phase {
        case .idle, .paused:
            "play.fill"
        case .running:
            "pause.fill"
        case .finished:
            "checkmark"
        }
    }

    private var accessibilityTitle: String {
        switch phase {
        case .idle:
            "Start \(detectedTimer.label) timer, \(clockText)"
        case .running:
            "Pause \(detectedTimer.label) timer, \(clockText)"
        case .paused:
            "Resume \(detectedTimer.label) timer, \(clockText)"
        case .finished:
            "\(detectedTimer.label) timer finished"
        }
    }

    private func toggleTimer() {
        switch phase {
        case .idle, .paused:
            Task {
                await viewModel.startTimer(id: detectedTimer.id)
            }
        case .running:
            viewModel.pauseTimer(id: detectedTimer.id)
        case .finished:
            viewModel.resetTimer(id: detectedTimer.id)
        }
    }

    /// The Live Activity shows a paused timer these same digits, so the
    /// format lives in the source both targets compile.
    private static func clockText(for totalSeconds: Int) -> String {
        CookingTimerClock.text(for: totalSeconds)
    }
}
