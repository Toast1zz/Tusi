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
