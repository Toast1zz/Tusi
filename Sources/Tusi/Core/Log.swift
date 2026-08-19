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
