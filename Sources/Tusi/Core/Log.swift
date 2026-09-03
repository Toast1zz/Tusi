import os
import Foundation

/// Central logging for Tusi. Wraps `os.Logger` with per-module categories so logs can
/// be filtered in Console.app (`log stream --predicate 'subsystem == "com.tusi.app"'`)
/// and are low-overhead when nobody is watching.
///
/// Nothing here is user-facing: OSLog output goes to the unified log, not the panel.
/// The point is that a production failure (request error, keychain write failure,
/// update check failure) leaves a trail instead of failing silently.
enum Log {
    private static let subsystem = "com.tusi.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let translation = Logger(subsystem: subsystem, category: "translation")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let update = Logger(subsystem: subsystem, category: "update")
    static let sound = Logger(subsystem: subsystem, category: "sound")
}

/// Records the panel's height chain, and dumps it when the panel ends up the wrong size.
///
/// The panel's height is not one measurement, it is a short chain handed along in
/// sequence — the result text measures itself, which sizes the result viewport, which
/// sizes the content, which sizes the window — and every link is a preference feeding a
/// `@State` that feeds the next link's frame. SwiftUI does not promise to redeliver a
/// preference for the layout its own state write caused, so a link can go quiet, and
/// when one does the window stays sized for the previous result. That failure is
/// invisible in a screenshot and unreadable in the code; the only thing that identifies
/// it is seeing which measurement stopped arriving.
///
/// So the chain is always recorded — into memory, not the log: a bounded ring that costs
/// an array append per layout pass and produces no output at all while the panel is
/// behaving. `PanelController`'s own fit audit dumps it when, and only when, the window
/// and the content actually disagree. That is deliberately not a debug-build feature:
/// this class of bug is timing-dependent, and a diagnostic that is absent from the build
/// people actually run is a diagnostic that is absent when it matters.
///
/// For a live per-hop stream (deep dives, not incident evidence):
///
///     defaults write com.tusi.app heightDiagnostics -bool true   # then relaunch
///     /usr/bin/log show --predicate 'subsystem == "com.tusi.app"' --last 10m --style compact | grep height:
///
/// Use the full path: a shell function named `log` is a common thing to have, and it
/// silently eats the arguments.
enum HeightTrace {
    /// Read once. A diagnostic that re-reads UserDefaults on every layout pass would be
    /// a cost paid by every user for a switch almost nobody turns on.
    static let isVerbose = UserDefaults.standard.bool(forKey: "heightDiagnostics")

    /// Lock-guarded rather than main-actor-isolated: SwiftUI's `onPreferenceChange`
    /// hands its action a `@Sendable` closure, so the recording side cannot require an
    /// actor without pushing hops onto the very call sites being measured.
    private final class Ring: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var lastDump: Date?
        /// A few translations' worth of chain — long enough to show what the measurements
        /// were doing before the one that went missing, short enough to stay free.
        private let limit = 48
        /// A dump is evidence, not a stream. One incident's worth per half minute.
        private let cooldown: TimeInterval = 30

        func append(_ entry: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(entry)
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
        }

        /// Returns the recorded chain and clears it, or nil while the cooldown holds.
        func drain(now: Date) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            if let lastDump, now.timeIntervalSince(lastDump) < cooldown { return nil }
            guard !entries.isEmpty else { return nil }
            lastDump = now
            let drained = entries
            entries.removeAll(keepingCapacity: true)
            return drained
        }
    }

    private static let ring = Ring()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: @autoclosure () -> String) {
        // Evaluated into a local first: the logger's string interpolation is an escaping
        // autoclosure, which a non-escaping parameter cannot be captured by.
        let text = message()
        ring.append("\(stamp.string(from: Date())) \(text)")
        guard isVerbose else { return }
        Log.app.notice("height: \(text, privacy: .public)")
    }

    /// Writes the recorded chain out under `reason`. Called when the panel's size and its
    /// content's size are found to disagree — the moment the record is worth something.
    static func dump(reason: String) {
        guard let entries = ring.drain(now: Date()) else { return }
        Log.app.error("height mismatch: \(reason, privacy: .public) — chain follows (\(entries.count, privacy: .public) entries)")
        for entry in entries {
            Log.app.error("height chain: \(entry, privacy: .public)")
        }
    }
}
