import Foundation

/// Why the last translation failed, at the granularity the error box needs to offer a
/// useful action. Deliberately coarse: the user-facing message already says what went
/// wrong, so this only has to answer "what should the button do about it".
enum FailureKind: Equatable {
    /// No slot is filled in at all — retrying cannot help, only configuring can.
    case notConfigured
    /// Local-model mode is on but its slot is incomplete.
    case localModelNotConfigured
    /// The endpoint rejected the key (or the account behind it).
    case credentials
    /// The base URL or the response protocol is wrong — a settings problem, not a
    /// network one.
    case configuration
    /// Network hiccup, rate limit, 5xx, timeout, dropped stream: worth another attempt.
    case transient
    /// Anything unclassified. Retry is the honest default.
    case unknown

    static func classify(_ error: Error) -> FailureKind {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .emptyKey:
                return .notConfigured
            case .invalidURL, .insecureURL, .invalidResponse:
                return .configuration
            case .truncatedStream, .watchdogTimeout:
                return .transient
            case .emptyResponse:
                return .unknown
            case .http(let code, _):
                switch code {
                case 401, 403: return .credentials
                // Out of credit is an account problem the user fixes off-device, but the
                // panel's only lever is the same one: which key/profile is being used.
                case 402: return .credentials
                case 408, 429: return .transient
                default: return code >= 500 ? .transient : .unknown
                }
            }
        }
        if error is URLError { return .transient }
        return .unknown
    }

    /// Whether trying the exact same request again has any chance of a different result.
    var isWorthRetrying: Bool {
        switch self {
        case .transient, .unknown: return true
        case .notConfigured, .localModelNotConfigured, .credentials, .configuration: return false
        }
    }
}

/// A short, copyable, de-identified account of the app's state at the moment something
/// failed — the thing a user can paste into a bug report without having to be told which
/// details matter and which ones must never leave their machine.
///
/// What it deliberately never contains: the API key, the text being translated, the
/// translated result, and the full base URL (which can carry a private path or token).
/// Only the host is reported, because "which endpoint" is the useful half and "which
/// path" is the sensitive half.
enum Diagnostics {
    struct Report {
        var appVersion: String
        var systemVersion: String
        var primaryHost: String
        var primaryModel: String
        var backupHost: String
        var localHost: String
        var usingLocalModel: Bool
        var raceEnabled: Bool
        var multiLanguageMode: Bool
        var target: String
        var failure: String?
        var failureKind: FailureKind?
    }

    static func text(for report: Report, timestamp: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("Tusi \(report.appVersion) · macOS \(report.systemVersion)")
        lines.append("time: \(ISO8601DateFormatter().string(from: timestamp))")
        lines.append("primary: \(describe(host: report.primaryHost, model: report.primaryModel))")
        lines.append("backup: \(describe(host: report.backupHost, model: nil))")
        if report.usingLocalModel || !report.localHost.isEmpty {
            lines.append("local: \(describe(host: report.localHost, model: nil))"
                + (report.usingLocalModel ? " (in use)" : ""))
        }
        lines.append("race: \(report.raceEnabled ? "on" : "off") · multi-language: \(report.multiLanguageMode ? "on" : "off")")
        lines.append("target: \(report.target)")
        if let failure = report.failure {
            // The provider's message can be an HTML page or a stack trace; one clamped
            // line keeps the receipt readable and keeps a hostile payload from filling
            // the user's clipboard.
            lines.append("error: \(singleLine(failure, limit: 300))")
        }
        if let kind = report.failureKind {
            lines.append("kind: \(String(describing: kind))")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(host: String, model: String?) -> String {
        let host = host.isEmpty ? "—" : host
        guard let model, !model.isEmpty else { return host }
        return "\(host) · \(model)"
    }

    private static func singleLine(_ value: String, limit: Int) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }
}
