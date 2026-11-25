import Foundation

/// The unsaved edit of one service page. Every field on the page edits the draft; the
/// store changes only when the page is saved, and leaving the page drops the draft.
///
/// The draft remembers the profile it started from, so a field the user never touched
/// keeps following the store (the local model picker, a Keychain read that lands late)
/// instead of the draft writing a stale copy back over it on save.
struct ProfileDraft: Equatable {
    private(set) var base: APIProfile
    var edited: APIProfile

    init(_ profile: APIProfile) {
        base = profile
        edited = profile
    }

    /// Reconciles an asynchronous store selection change without wiping other unsaved fields.
    mutating func acceptStoreModel(_ model: String) {
        base.model = model
        edited.model = model
    }

    /// `stored` with only the fields the user changed laid over it.
    func resolved(over stored: APIProfile) -> APIProfile {
        var result = stored
        Self.carry(\.baseURL, from: self, into: &result)
        Self.carry(\.apiKey, from: self, into: &result)
        Self.carry(\.model, from: self, into: &result)
        Self.carry(\.providerOrder, from: self, into: &result)
        Self.carry(\.outputProtocolPreference, from: self, into: &result)
        return result
    }

    private static func carry<Value: Equatable>(
        _ field: WritableKeyPath<APIProfile, Value>,
        from draft: ProfileDraft,
        into result: inout APIProfile
    ) {
        if draft.edited[keyPath: field] != draft.base[keyPath: field] {
            result[keyPath: field] = draft.edited[keyPath: field]
        }
    }
}
