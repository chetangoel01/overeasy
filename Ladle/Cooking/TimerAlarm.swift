import AVFoundation
import Foundation
import UIKit

@MainActor
protocol TimerChimePlaying: AnyObject {
    func playChime()
}

/// The foreground half of a finished timer's alert.
///
/// A notification is silenced by the ringer switch; a kitchen timer is not.
/// While the app is in front, a finished timer sounds the same chime through
/// an `AVAudioSession` playback category instead, and keeps sounding it until
/// the cook acknowledges the timer — capped, so a phone left on a counter
/// cannot ring all afternoon.
@MainActor
final class TimerAlarm {
    /// Long enough to be a reminder rather than an alarm clock.
    static let repeatInterval: TimeInterval = 5
    static let maximumRings = 6

    private struct Ring {
        var count: Int
        var nextAt: Date
    }

    private let player: any TimerChimePlaying
    private var rings: [UUID: Ring] = [:]

    init(player: any TimerChimePlaying = SystemTimerChimePlayer()) {
        self.player = player
    }

    /// Sounds for every finished timer the cook has not answered yet.
    ///
    /// Acknowledging is the finished timer card's own Reset — the timer
    /// leaves `.finished` and drops out of `finishedTimerIDs`, which is what
    /// stops the ringing. No separate control, and nothing to dismiss.
    func tick(finishedTimerIDs: Set<UUID>, at date: Date) {
        rings = rings.filter { finishedTimerIDs.contains($0.key) }
        // Sorted so a recipe with two timers finishing together rings in a
        // fixed order rather than whatever the set iterates.
        for timerID in finishedTimerIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let ring = rings[timerID] else {
                sound(timerID, at: date, count: 0)
                continue
            }
            guard ring.count < Self.maximumRings, date >= ring.nextAt else {
                continue
            }
            sound(timerID, at: date, count: ring.count)
        }
    }

    /// Marks timers as already answered without sounding them: their
    /// notification was delivered while the app was away, and that was the
    /// alarm.
    func suppress(_ timerIDs: Set<UUID>) {
        for timerID in timerIDs where !rings.keys.contains(timerID) {
            rings[timerID] = Ring(
                count: Self.maximumRings,
                nextAt: .distantFuture
            )
        }
    }

    func reset() {
        rings.removeAll()
    }

    private func sound(_ timerID: UUID, at date: Date, count: Int) {
        player.playChime()
        rings[timerID] = Ring(
            count: count + 1,
            nextAt: date.addingTimeInterval(Self.repeatInterval)
        )
    }
}

@MainActor
final class SystemTimerChimePlayer: TimerChimePlaying {
    /// A knock rather than the success pattern the finished timer card
    /// already plays, so a repeat does not read as the same event again.
    private let haptics = UIImpactFeedbackGenerator(style: .heavy)
    private var player: AVAudioPlayer?
    private var deactivation: Task<Void, Never>?

    func playChime() {
        guard let player = loadedPlayer() else {
            return
        }
        let session = AVAudioSession.sharedInstance()
        // `.playback` is what sounds with the ringer switch off;
        // `.duckOthers` lowers whatever is playing instead of stopping it.
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        player.currentTime = 0
        player.play()
        haptics.impactOccurred()
        // Deactivating straight after `play()` would cut the chime off, so
        // the session is handed back once the sound has finished.
        deactivation?.cancel()
        deactivation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(player.duration + 0.1))
            guard !Task.isCancelled else {
                return
            }
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            self?.deactivation = nil
        }
    }

    private func loadedPlayer() -> AVAudioPlayer? {
        if let player {
            return player
        }
        guard let url = Bundle.main.url(
            forResource: "TimerChime",
            withExtension: "wav"
        ) else {
            return nil
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        return player
    }
}
