import UserNotifications
import XCTest

@testable import Ladle

/// The timer tone is the system's own Calypso, read at runtime. What matters
/// is the two ways it reaches a cook: straight from the system for the
/// foreground alarm, and as a copy under `Library/Sounds` for the
/// notification — and that neither path can silence a timer when the file
/// is not where this OS keeps it.
final class TimerToneTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "timer-tone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheNotificationSoundIsACopyOfTheSystemToneMadeOnce() throws {
        let source = scratch.appending(path: "Calypso.caf")
        try Data("tone".utf8).write(to: source)
        let library = scratch.appending(path: "Library")

        let sound = TimerTone.notificationSound(source: source, library: library)

        XCTAssertEqual(
            sound,
            UNNotificationSound(
                named: UNNotificationSoundName(TimerTone.notificationSoundName)
            )
        )
        let copy = library
            .appending(path: "Sounds")
            .appending(path: TimerTone.notificationSoundName)
        XCTAssertEqual(try Data(contentsOf: copy), Data("tone".utf8))

        // A second call keeps the copy it has rather than copying again —
        // and keeps working after the source is gone, which is the point of
        // holding a copy at all.
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(
            TimerTone.notificationSound(source: source, library: library),
            sound
        )
    }

    func testAMissingSystemToneFallsBackToTheDefaultAlert() {
        let missing = scratch.appending(path: "nowhere.caf")
        let library = scratch.appending(path: "Library")

        XCTAssertEqual(
            TimerTone.notificationSound(source: missing, library: library),
            .default
        )
        XCTAssertNil(TimerTone.playbackURL(source: missing))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: library.appending(path: "Sounds").path
            ),
            "nothing to copy, nothing created"
        )
    }

    func testThisOSKeepsCalypsoWhereTheToneExpectsIt() {
        // The simulator runtime mirrors the device filesystem, so a failure
        // here means the path moved and both fallbacks are what ships.
        XCTAssertEqual(TimerTone.playbackURL(), TimerTone.systemURL)
    }
}
