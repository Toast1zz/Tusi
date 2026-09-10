import Foundation

/// One physical Return press. Cancellation and completion remain latched until
/// key-up, so system key repeat can never start another paid request.
struct ReturnHold {
    static let duration: TimeInterval = 1.5
    private(set) var keyCode: UInt16?
    private var startedAt: TimeInterval?

    mutating func begin(keyCode: UInt16, now: TimeInterval) {
        guard self.keyCode == nil else { return }
        self.keyCode = keyCode
        startedAt = now
    }

    func progress(now: TimeInterval) -> Double? {
        startedAt.map { min(1, max(0, (now - $0) / Self.duration)) }
    }

    mutating func fireIfReady(now: TimeInterval) -> Bool {
        guard let progress = progress(now: now), progress >= 1 else { return false }
        startedAt = nil
        return true
    }

    mutating func cancel() { startedAt = nil }

    /// A short, uncancelled press still performs the ordinary submit action.
    mutating func release(keyCode: UInt16) -> Bool {
        guard self.keyCode == keyCode else { return false }
        let submit = startedAt != nil
        self = ReturnHold()
        return submit
    }
}
