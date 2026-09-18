import AudioToolbox
import Foundation
import UserNotifications

/// The sound a finished timer makes: Calypso, one of iOS's own alert tones.
/// The owner chose it by ear on September 17, 2026 over a set of bundled
/// candidates (#161, #177).
///
/// Apple's tone files cannot ship inside the app, so the tone is read from
/// the system at runtime. The foreground alarm plays it straight from there;
/// the notification sound is a copy placed in the app's `Library/Sounds`,
/// which is where UserNotifications looks for a sound the app did not
/// bundle. Both fall back when an OS does not keep the file where this one
/// does — the alarm to the system's own player, the notification to the
/// default alert — so a missing tone can never silence a timer.
enum TimerTone {
    /// On a device the tone lives under `/System`. A simulator process sees
    /// the Mac's `/System` at that path and its own under `SIMULATOR_ROOT`,
    /// so the root is prefixed there — which is what makes the simulator
    /// exercise the same path a phone does, rather than the fallbacks.
    static let systemURL: URL = {
        let root = ProcessInfo.processInfo.environment["SIMULATOR_ROOT"] ?? ""
        return URL(
            fileURLWithPath: root + "/System/Library/Audio/UISounds/New/Calypso.caf"
        )
    }()

    /// Calypso's system sound id, for the alarm's fallback path. Unlike the
    /// playback session the alarm normally uses, this respects the ringer.
    static let systemSoundID: SystemSoundID = 1315

    /// The copy's name under `Library/Sounds`. Neutral on purpose: it is what
    /// the app calls its timer sound, whichever tone stands behind it.
    static let notificationSoundName = "OvereasyTimer.caf"

    /// Where the foreground alarm reads the tone, or nil when this OS does not
    /// have it.
    static func playbackURL(
        source: URL = systemURL,
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.isReadableFile(atPath: source.path) ? source : nil
    }

    /// The notification's sound: Calypso once its copy is in place, the
    /// default alert otherwise. Copying happens on the first call and is
    /// skipped once the copy exists.
    static func notificationSound(
        source: URL = systemURL,
        library: URL? = nil,
        fileManager: FileManager = .default
    ) -> UNNotificationSound {
        guard copyForNotifications(
            source: source,
            library: library,
            fileManager: fileManager
        ) != nil else {
            return .default
        }
        return UNNotificationSound(
            named: UNNotificationSoundName(notificationSoundName)
        )
    }

    @discardableResult
    static func copyForNotifications(
        source: URL = systemURL,
        library: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let library = library ?? fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let sounds = library.appending(path: "Sounds", directoryHint: .isDirectory)
        let destination = sounds.appending(path: notificationSoundName)
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        guard let source = playbackURL(source: source, fileManager: fileManager) else {
            return nil
        }
        do {
            try fileManager.createDirectory(
                at: sounds,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
