import Foundation

/// How good a slot is expected to be, ordered from cheapest to best. Escalation only
/// ever moves up this ladder, which is what makes "press ⏎ again for a better answer"
/// a promise the app can keep rather than a re-roll of the same model.
enum TranslationTier: String, Equatable, Sendable, Comparable {
    case local
    case online

    private var rank: Int {
        switch self {
        case .local: return 0
        case .online: return 1
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Where a translation begins. The user-facing half of what used to be
/// `useLocalModel` — except the local slot is no longer a standing mode that bypasses
/// the rest of the app, it is simply the first stage of a route that can continue.
enum RouteStart: String, Equatable, Sendable, CaseIterable {
    case local
    case online
}

/// What to do with the two online slots. Replaces the `fallbackEnabled` /
/// `raceFastestEnabled` pair, which were never independent: racing silently did
/// nothing unless fallback was also on, because the race path read the same resolved
/// chain that fallback gated.
enum OnlineStrategy: String, Equatable, Sendable, CaseIterable {
    /// Ask the primary; only if it fails does the backup hear about it.
    case failover
    /// Ask both at once and keep whichever finishes first with a usable answer.
    case concurrent
}

/// One attempt at answering, and the slots it is allowed to use.
///
/// A stage is the unit the engine advances through. Advancing on *failure* is what
/// used to be called failover; advancing on *request* is escalation. They were three
/// separate branches of `translate()` and are now one loop with two triggers, which is
/// the whole reason "⏎ again for a better answer" costs almost no new machinery.
struct RouteStage: Equatable, Sendable {
    enum Strategy: Equatable, Sendable {
        /// One slot, with the ordinary single-provider retry on transient failures.
        case single
        /// Try the slots in order, moving on when one fails before producing output.
        case failover
        /// Fire every slot at once; first usable answer wins and cancels the rest.
        case concurrent
    }

    var tier: TranslationTier
    var slots: [Int]
    var strategy: Strategy
}

/// The ordered stages one translation may pass through. Built by `SettingsStore.route`
/// from the two preferences the user actually sets, plus which slots are filled in —
/// so an unusable slot simply is not in the route, and no code downstream has to
/// re-check usability.
struct TranslationRoute: Equatable, Sendable {
    var stages: [RouteStage]

    var isEmpty: Bool { stages.isEmpty }

    func stage(at index: Int) -> RouteStage? {
        stages.indices.contains(index) ? stages[index] : nil
    }

    /// Whether a stage above `index` exists — the precondition for offering escalation.
    /// Deliberately not "is there another stage": a route whose remaining stage is the
    /// same tier would promise a better answer and deliver a coin flip.
    func hasHigherTier(after index: Int) -> Bool {
        guard let current = stage(at: index) else { return false }
        return stages.dropFirst(index + 1).contains { $0.tier > current.tier }
    }

    /// The next stage strictly above `index`'s tier, and its position. Escalation skips
    /// same-tier stages rather than walking into one.
    func nextHigherStage(after index: Int) -> (index: Int, stage: RouteStage)? {
        guard let current = stage(at: index) else { return nil }
        for position in (index + 1)..<stages.count where stages[position].tier > current.tier {
            return (position, stages[position])
        }
        return nil
    }
}
