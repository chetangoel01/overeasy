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

@MainActor
protocol TimerNotificationScheduling: AnyObject {
    func schedule(
        timerID: UUID,
        label: String,
        durationSeconds: Int
    ) async

    func cancel(timerID: UUID)
}

@MainActor
final class LocalTimerNotificationScheduler:
    TimerNotificationScheduling
{
    private let center: UNUserNotificationCenter

    init(
        center: UNUserNotificationCenter = .current()
    ) {
        self.center = center
    }

    func schedule(
        timerID: UUID,
        label: String,
        durationSeconds: Int
    ) async {
        guard durationSeconds > 0 else {
            return
        }

        do {
            let isAuthorized = try await center.requestAuthorization(
                options: [.alert, .sound]
            )
            guard isAuthorized else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "\(label) is ready"
            content.body = "Your Ladle timer has finished."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: Self.identifier(for: timerID),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval(durationSeconds),
                    repeats: false
                )
            )
            try await center.add(request)
        } catch {
            // The in-app timer remains usable when notifications are denied.
        }
    }

    func cancel(timerID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(for: timerID)]
        )
    }

    private static func identifier(for timerID: UUID) -> String {
        "ladle.cooking-timer.\(timerID.uuidString)"
    }
}

enum RecipeTimerPhase: Equatable {
    case idle
    case running
    case paused
    case finished
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
    @Bindable var viewModel: CookingViewModel
    let detectedTimer: DetectedTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                Button {
                    toggleTimer()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: timerIcon)
                            .font(.system(size: 15, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(actionTitle)
                                .font(LadleTypography.metadata)
                            Text(clockText)
                                .font(
                                    .system(
                                        size: 19,
                                        weight: .semibold,
                                        design: .monospaced
                                    )
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(LadleTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 58)
                    .background(
                        LadleTheme.review,
                        in: RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control,
                            style: .continuous
                        )
                    )
                }
                .accessibilityLabel(accessibilityTitle)

                if phase != .idle {
                    Button {
                        viewModel.resetTimer(id: detectedTimer.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LadleTheme.paprika)
                            .frame(width: 48, height: 48)
                            .background(LadleTheme.field, in: Circle())
                    }
                    .accessibilityLabel(
                        "Reset \(detectedTimer.label) timer"
                    )
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

    private static func clockText(for totalSeconds: Int) -> String {
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
