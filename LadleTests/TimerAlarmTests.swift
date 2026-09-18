import Foundation
import XCTest
@testable import Ladle

@MainActor
final class TimerAlarmTests: XCTestCase {
    func testAFinishedTimerSoundsAtOnceAndThenOnTheRepeatInterval() {
        let player = TestChimePlayer()
        let alarm = TimerAlarm(player: player)
        let timerID = UUID()
        var now = Date(timeIntervalSince1970: 1_000)

        alarm.tick(finishedTimerIDs: [timerID], at: now)
        XCTAssertEqual(player.chimes, 1)

        // The heartbeat runs every second; only the interval sounds.
        for _ in 0..<4 {
            now.addTimeInterval(1)
            alarm.tick(finishedTimerIDs: [timerID], at: now)
        }
        XCTAssertEqual(player.chimes, 1)

        now.addTimeInterval(1)
        alarm.tick(finishedTimerIDs: [timerID], at: now)
        XCTAssertEqual(player.chimes, 2)
    }

    func testTheAlarmStopsAtItsCapSoAPhoneOnACounterCannotRingOn() {
        let player = TestChimePlayer()
        let alarm = TimerAlarm(player: player)
        let timerID = UUID()
        var now = Date(timeIntervalSince1970: 1_000)

        for _ in 0..<200 {
            alarm.tick(finishedTimerIDs: [timerID], at: now)
            now.addTimeInterval(1)
        }

        XCTAssertEqual(player.chimes, TimerAlarm.maximumRings)
    }

    func testAcknowledgingTheTimerStopsTheAlarm() {
        let player = TestChimePlayer()
        let alarm = TimerAlarm(player: player)
        let timerID = UUID()
        var now = Date(timeIntervalSince1970: 1_000)

        alarm.tick(finishedTimerIDs: [timerID], at: now)
        XCTAssertEqual(player.chimes, 1)

        // Reset on the finished timer card: it leaves `.finished`, so it
        // leaves the set the alarm rings for. There is no other control.
        now.addTimeInterval(TimerAlarm.repeatInterval)
        alarm.tick(finishedTimerIDs: [], at: now)
        now.addTimeInterval(TimerAlarm.repeatInterval)
        alarm.tick(finishedTimerIDs: [], at: now)

        XCTAssertEqual(player.chimes, 1)
    }

    func testEachTimerGetsItsOwnRunOfRings() {
        let player = TestChimePlayer()
        let alarm = TimerAlarm(player: player)
        let first = UUID()
        let second = UUID()
        var now = Date(timeIntervalSince1970: 1_000)

        alarm.tick(finishedTimerIDs: [first], at: now)
        now.addTimeInterval(1)
        alarm.tick(finishedTimerIDs: [first, second], at: now)

        XCTAssertEqual(
            player.chimes,
            2,
            "The second timer sounds on the tick it finishes, not on the"
                + " first timer's cadence"
        )
    }

    func testASuppressedTimerNeverSounds() {
        let player = TestChimePlayer()
        let alarm = TimerAlarm(player: player)
        let timerID = UUID()
        var now = Date(timeIntervalSince1970: 1_000)

        // Finished while the app was in the background, or before a
        // relaunch: the notification was its alarm.
        alarm.suppress([timerID])
        for _ in 0..<20 {
            alarm.tick(finishedTimerIDs: [timerID], at: now)
            now.addTimeInterval(1)
        }

        XCTAssertEqual(player.chimes, 0)
    }

    func testSuppressionDoesNotSilenceATimerAlreadyRinging() {
        let player = TestChimePlayer()
        let alarm = TimerAlarm(player: player)
        let timerID = UUID()
        var now = Date(timeIntervalSince1970: 1_000)

        alarm.tick(finishedTimerIDs: [timerID], at: now)
        alarm.suppress([timerID])
        now.addTimeInterval(TimerAlarm.repeatInterval)
        alarm.tick(finishedTimerIDs: [timerID], at: now)

        XCTAssertEqual(player.chimes, 2)
    }
}

@MainActor
private final class TestChimePlayer: TimerChimePlaying {
    private(set) var chimes = 0

    func playChime() {
        chimes += 1
    }
}
