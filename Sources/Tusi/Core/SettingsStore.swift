import Foundation
import Combine
import ServiceManagement

struct APIConfig: Equatable, Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    /// Comma/whitespace-separated backend names (e.g. "novita, together") sent as
    /// OpenRouter's `provider.order` routing hint. It is sent only to OpenRouter hosts;
    /// strict gateways must not receive this provider-specific top-level field.
    var providerOrder: String = ""
    var outputProtocolPreference: TranslationProtocolPreference = .automatic

    /// Whether this endpoint needs an API key. Local (loopback) inference servers —
    /// Ollama, LM Studio, llama.cpp-server — authenticate differently or not at all, so a
    /// `localhost` / `127.0.0.0/8` / `::1` endpoint is allowed to have an empty key.
    /// Anything unresolved (empty or unparseable base URL) conservatively requires auth.
    var requiresAuth: Bool {
        !TranslationService.isLoopback(displayHost)
    }

    var isUsable: Bool {
        let valid = !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard valid else { return false }
        // Local endpoints can omit the key; remote ones must still have one.
        return !requiresAuth
            || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Host of the base URL, used as a display name for the slot ("api.deepseek.com").
    var displayHost: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let withScheme = TranslationService.normalizedBaseURLString(trimmed)
        return URL(string: withScheme)?.host ?? ""
    }

    /// Parsed provider names, in the order they should be tried.
    var providerOrderList: [String] {
        providerOrder
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// One of the two BYOK slots. Everything is user-typed — no baked-in providers.
struct APIProfile: Equatable, Sendable {
    var baseURL = ""
    var apiKey = ""
    var model = ""
    var providerOrder = ""
    var outputProtocolPreference: TranslationProtocolPreference = .automatic

    var config: APIConfig {
        APIConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            providerOrder: providerOrder,
            outputProtocolPreference: outputProtocolPreference
        )
    }
    var isUsable: Bool { config.isUsable }
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    /// TUSI_PREVIEW runs against a throwaway suite and never touches the Keychain,
    /// so screenshot runs can't clobber real credentials. Read by TranslationEngine
    /// too, so preview runs keep their history in a scratch location as well.
    let isPreview: Bool

    /// Three slots: index 0 and 1 are the primary/backup pair used by ordinary
    /// automatic translation (and the race feature below); index 2 is a standalone
    /// local-model slot that never participates in that automatic flow — see
    /// `localProfileIndex`.
    @Published var profiles: [APIProfile] {
        didSet { persistProfiles(previous: oldValue) }
    }

    /// The dedicated local-model slot. Deliberately outside the primary/backup pair:
    /// it is never part of `resolvedChain`, never raced, never a failover target —
    /// invoked only by the user explicitly asking to translate with it. Having a
    /// dedicated slot means primary/backup are expected to be online providers by
    /// convention, not just by the runtime `requiresAuth` check `raceFastestEnabled`
    /// still does defensively (nothing stops a user from typing a loopback URL into
    /// slot 0/1 anyway — that check stays as the real guarantee).
    static let localProfileIndex = 2

    /// Set when a Keychain write failed. The pending snapshot is retained so a later
    /// edit or application shutdown can retry it instead of silently losing the key.
    @Published private(set) var keychainError: String?
    /// True when the failure behind `keychainError` is worth trying again — the device
    /// was locked, or the access prompt was denied. Corrupt data is not: reading it a
    /// second time returns the same corrupt bytes, and the only way out is re-entering
    /// the key. Drives whether the settings page offers a retry.
    @Published private(set) var keychainErrorIsRetryable = false
    /// True briefly after API keys land in the Keychain. The save is debounced
    /// (250ms) and otherwise silent — a one-time confirmation tells the user the
    /// typed key was actually persisted, instead of leaving them guessing.
    @Published private(set) var keychainSaved = false

    private var keychainSaveTask: Task<Void, Never>?
    private var keychainSavedTask: Task<Void, Never>?
    private var pendingKeychainKeys: [Int: String]?
    private var profileSaveTask: Task<Void, Never>?
    private var pendingProfiles: [APIProfile]?

    @Published var panelWidth: CGFloat = Theme.panelMinWidth {
        didSet { defaults.set(Double(panelWidth), forKey: "panelWidth") }
    }
    @Published var primaryIndex: Int {
        didSet { defaults.set(primaryIndex, forKey: "primaryIndex") }
    }
    @Published var fallbackEnabled: Bool {
        didSet { defaults.set(fallbackEnabled, forKey: "fallbackEnabled") }
    }
    /// Race primary and backup concurrently and commit whichever answers first,
    /// instead of trying them strictly in order. Off by default: this doubles the
    /// number of requests sent per translation whenever both slots are usable, which
    /// is a real cost/quota trade-off the user must opt into, not a free win.
    ///
    /// Only ever applies when BOTH slots are non-loopback (`requiresAuth == true`) —
    /// a local model's near-zero network latency would trivially win every race
    /// regardless of whether its answers are actually good enough, which defeats the
    /// point of racing two comparable online providers. When either slot is local,
    /// this setting has no effect and the ordinary sequential primary→backup behavior
    /// (governed by `fallbackEnabled`) applies unchanged.
    @Published var raceFastestEnabled: Bool {
        didSet { defaults.set(raceFastestEnabled, forKey: "raceFastestEnabled") }
    }
    /// Whether a race's winner gets named in a one-time toast (Toast.raceWon). On by
    /// default when racing itself is on — racing silently otherwise looks identical
    /// to ordinary translation, which is confusing the first few times. Independent
    /// key so turning the toast off doesn't also turn off racing itself.
    @Published var raceToastEnabled: Bool {
        didSet { defaults.set(raceToastEnabled, forKey: "raceToastEnabled") }
    }
    /// Standing mode switch, flipped from the local-model slot's own Settings tab —
    /// when on, `translate()` talks ONLY to `localProfileIndex`: no primary/backup, no
    /// race, no failover. This is the entire manual-only contract for that slot; there
    /// is no other trigger anywhere in the app.
    @Published var useLocalModel: Bool {
        didSet { defaults.set(useLocalModel, forKey: "useLocalModel") }
    }
    @Published var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: "autoCopy") }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }
    @Published var tone: Tone {
        didSet { defaults.set(tone.rawValue, forKey: "tone") }
    }
    /// Multi-language mode: the user picks the target explicitly instead of the
    /// automatic CN↔EN pairing.
    @Published var multiLanguageMode: Bool {
        didSet { defaults.set(multiLanguageMode, forKey: "multiLanguageMode") }
    }
    /// Master sound switch. Persisted in UserDefaults like every other preference;
    /// applied live to the shared SoundPlayer so mute is immediate.
    @Published var soundEnabled: Bool {
        didSet {
            guard soundEnabled != oldValue else { return }
            defaults.set(soundEnabled, forKey: "soundEnabled")
            SoundPlayer.shared.enabled = soundEnabled
        }
    }
    /// All five rebindable shortcuts. Missing entries fall back to the action's default.
    @Published var shortcuts: [ShortcutAction: KeyCombo] {
        didSet { persistShortcuts() }
    }
    /// Shortcuts the user has explicitly unbound. `shortcut(_:)` returns nil for these,
    /// and the action is left to its non-keyboard affordance (button, menu-bar icon…).
    @Published var disabledShortcuts: Set<ShortcutAction> {
        didSet { persistDisabledShortcuts() }
    }

    func shortcut(_ action: ShortcutAction) -> KeyCombo? {
        if disabledShortcuts.contains(action) { return nil }
        return shortcuts[action] ?? action.defaultCombo
    }

    func setShortcut(_ combo: KeyCombo, for action: ShortcutAction) {
        disabledShortcuts.remove(action)
        shortcuts[action] = combo
    }

    /// Unbinds a shortcut entirely (empty state). The previous combo is kept in
    /// `shortcuts` so it can be reinstated by re-recording or restoring the default.
    func clearShortcut(for action: ShortcutAction) {
        disabledShortcuts.insert(action)
    }
    /// Optional freeform instruction appended to the system prompt — glossary entries,
    /// formatting rules, house style. Additive on purpose: it can't replace the
    /// "output only the translation" contract the rest of the app depends on.
    @Published var extraInstruction: String {
        didSet { defaults.set(extraInstruction, forKey: "extraInstruction") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            launchAtLoginError = nil
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLoginError = error.localizedDescription
                launchAtLogin = oldValue
            }
        }
    }
    @Published private(set) var launchAtLoginError: String?
    init(preview: Bool? = nil) {
        isPreview = preview ?? (ProcessInfo.processInfo.environment["TUSI_PREVIEW"] != nil)
        if isPreview {
            let suite = "com.tusi.preview.scratch"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = .standard
        }

        primaryIndex = defaults.object(forKey: "primaryIndex") as? Int == 1 ? 1 : 0
        fallbackEnabled = defaults.object(forKey: "fallbackEnabled") as? Bool ?? true
        raceFastestEnabled = defaults.bool(forKey: "raceFastestEnabled")
        raceToastEnabled = defaults.object(forKey: "raceToastEnabled") as? Bool ?? true
        useLocalModel = defaults.bool(forKey: "useLocalModel")
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        tone = Tone(rawValue: defaults.string(forKey: "tone") ?? "") ?? .standard
        multiLanguageMode = defaults.bool(forKey: "multiLanguageMode")
        // Sound is opt-out and follows the system output volume.
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        let storedWidth = defaults.double(forKey: "panelWidth")
        if storedWidth > 0 {
            panelWidth = min(max(CGFloat(storedWidth), Theme.panelMinWidth), Theme.panelMaxWidth)
        }
        extraInstruction = defaults.string(forKey: "extraInstruction") ?? ""
        shortcuts = Self.loadShortcuts(defaults: defaults)
        disabledShortcuts = Self.loadDisabledShortcuts(defaults: defaults)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if isPreview {
            profiles = [APIProfile(), APIProfile(), APIProfile()]
        } else {
            let loaded = Self.loadProfiles(defaults: defaults)
            profiles = loaded.profiles
            keychainError = loaded.keychainError
            keychainErrorIsRetryable = loaded.retryable
        }

        // Sync the persisted sound preference into the shared player after every stored
        // property is initialized.
        SoundPlayer.shared.enabled = soundEnabled
    }

    // MARK: - Shortcut persistence

    private static func loadShortcuts(defaults: UserDefaults) -> [ShortcutAction: KeyCombo] {
        // The old single-shortcut layout stored copy under "copyShortcut.*"; fold it into
        // the new per-action layout so existing users keep their custom copy key.
        if !defaults.bool(forKey: "didMigrateShortcuts") {
            defaults.set(true, forKey: "didMigrateShortcuts")
            if defaults.object(forKey: "copyShortcut.keyCode") != nil,
               let display = defaults.string(forKey: "copyShortcut.display") {
                let base = "shortcut.\(ShortcutAction.copy.rawValue)"
                defaults.set(defaults.integer(forKey: "copyShortcut.keyCode"), forKey: "\(base).keyCode")
                defaults.set(defaults.integer(forKey: "copyShortcut.modifiers"), forKey: "\(base).modifiers")
                defaults.set(display, forKey: "\(base).display")
            }
        }

        var result: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases {
            let base = "shortcut.\(action.rawValue)"
            if let display = defaults.string(forKey: "\(base).display"),
               defaults.object(forKey: "\(base).keyCode") != nil {
                result[action] = KeyCombo(
                    keyCode: UInt16(defaults.integer(forKey: "\(base).keyCode")),
                    modifiers: UInt(defaults.integer(forKey: "\(base).modifiers")),
                    display: display
                )
            } else {
                result[action] = action.defaultCombo
            }
        }
        return result
    }

    private func persistShortcuts() {
        guard !isPreview else { return }
        for (action, combo) in shortcuts {
            let base = "shortcut.\(action.rawValue)"
            defaults.set(Int(combo.keyCode), forKey: "\(base).keyCode")
            defaults.set(Int(combo.modifiers), forKey: "\(base).modifiers")
            defaults.set(combo.display, forKey: "\(base).display")
        }
    }

    private static func loadDisabledShortcuts(defaults: UserDefaults) -> Set<ShortcutAction> {
        Set((defaults.stringArray(forKey: "disabledShortcuts") ?? []).compactMap(ShortcutAction.init(rawValue:)))
    }

    private func persistDisabledShortcuts() {
        guard !isPreview else { return }
        if disabledShortcuts.isEmpty {
            defaults.removeObject(forKey: "disabledShortcuts")
        } else {
            defaults.set(disabledShortcuts.map(\.rawValue).sorted(), forKey: "disabledShortcuts")
        }
    }

    // MARK: - Persistence

    private static func loadProfiles(defaults: UserDefaults) -> (profiles: [APIProfile], keychainError: String?, retryable: Bool) {
        // Pre-slot installs kept the primary's URL and model under unsuffixed keys.
        if !defaults.bool(forKey: "didMigrateProfiles") {
            defaults.set(true, forKey: "didMigrateProfiles")
            if let oldBase = defaults.string(forKey: "baseURL"), !oldBase.isEmpty {
                defaults.set(oldBase, forKey: "baseURL.0")
                defaults.set(defaults.string(forKey: "model") ?? "", forKey: "model.0")
                defaults.removeObject(forKey: "baseURL")
                defaults.removeObject(forKey: "model")
            }
        }

        // One read for both slots — see Keychain for why that matters.
        let keys: [Int: String]
        let keychainError: String?
        let retryable: Bool
        do {
            keys = try Keychain.migrateLegacyKeysIfNeeded() ?? Keychain.loadKeys()
            keychainError = nil
            retryable = false
        } catch {
            Log.keychain.error("keychain load failed: \(error.localizedDescription, privacy: .public)")
            keys = [:]
            keychainError = error.localizedDescription
            retryable = Self.isRetryableKeychainFailure(error)
        }

        let profiles = (0...localProfileIndex).map { index in
            APIProfile(
                baseURL: defaults.string(forKey: "baseURL.\(index)") ?? "",
                apiKey: keys[index] ?? "",
                model: defaults.string(forKey: "model.\(index)") ?? "",
                providerOrder: defaults.string(forKey: "providerOrder.\(index)") ?? "",
                outputProtocolPreference: loadOutputProtocolPreference(defaults: defaults, index: index)
            )
        }
        return (profiles, keychainError, retryable)
    }

    /// A locked Keychain resolves itself on unlock, and a denied prompt can be granted on
    /// the next attempt; both are worth a retry button. Anything else (corrupt payload,
    /// unclassified OSStatus) would just fail the same way.
    private static func isRetryableKeychainFailure(_ error: Error) -> Bool {
        guard let keychainError = error as? KeychainError else { return false }
        switch keychainError {
        case .invalidData:
            return false
        case .readFailed(let status), .operationFailed(let status):
            return keychainError.isTemporary
                || status == errSecUserCanceled
                || status == errSecAuthFailed
                || status == errSecNotAvailable
        }
    }

    private func persistProfiles(previous: [APIProfile]) {
        guard !isPreview else { return }

        let preferencesChanged = profiles.count != previous.count
            || zip(profiles, previous).contains {
                $0.baseURL != $1.baseURL
                    || $0.model != $1.model
                    || $0.providerOrder != $1.providerOrder
                    || $0.outputProtocolPreference != $1.outputProtocolPreference
            }
        if preferencesChanged {
            pendingProfiles = profiles
            scheduleProfileSave()
        }

        let keysChanged = profiles.count != previous.count
            || zip(profiles, previous).contains { $0.apiKey != $1.apiKey }
        if keysChanged {
            // Merge into existing pending dict instead of replacing: rapid edits to both
            // slots (within the debounce window) would otherwise lose the first slot's key.
            if pendingKeychainKeys == nil { pendingKeychainKeys = [:] }
            for (offset, profile) in profiles.enumerated() {
                pendingKeychainKeys?[offset] = profile.apiKey
            }
            scheduleKeychainSave()
        }
    }

    private func scheduleProfileSave() {
        profileSaveTask?.cancel()
        guard let profiles = pendingProfiles else { return }
        profileSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.saveProfiles(profiles)
        }
    }

    private func saveProfiles(_ profiles: [APIProfile]) {
        Self.saveProfilePreferences(profiles, defaults: defaults)
        pendingProfiles = nil
    }

    /// Internal pure-UserDefaults seams keep profile persistence testable without reading
    /// the real Keychain or touching the user's normal defaults domain.
    static func loadOutputProtocolPreference(defaults: UserDefaults, index: Int) -> TranslationProtocolPreference {
        TranslationProtocolPreference(
            rawValue: defaults.string(forKey: "outputProtocolPreference.\(index)") ?? ""
        ) ?? .automatic
    }

    static func saveProfilePreferences(_ profiles: [APIProfile], defaults: UserDefaults) {
        for (index, profile) in profiles.enumerated() {
            defaults.set(profile.baseURL, forKey: "baseURL.\(index)")
            defaults.set(profile.model, forKey: "model.\(index)")
            defaults.set(profile.providerOrder, forKey: "providerOrder.\(index)")
            defaults.set(profile.outputProtocolPreference.rawValue, forKey: "outputProtocolPreference.\(index)")
        }
    }

    private func scheduleKeychainSave() {
        keychainSaveTask?.cancel()
        guard let keys = pendingKeychainKeys else { return }
        keychainSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.saveKeychain(keys)
        }
    }

    private func saveKeychain(_ keys: [Int: String]) {
        do {
            try Keychain.saveKeys(keys)
            pendingKeychainKeys = nil
            keychainError = nil
            keychainErrorIsRetryable = false
            flashKeychainSaved()
        } catch {
            keychainError = error.localizedDescription
            keychainErrorIsRetryable = Self.isRetryableKeychainFailure(error)
            Log.keychain.error("keychain save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shows the "saved" confirmation for a beat, then clears it.
    private func flashKeychainSaved() {
        keychainSaved = true
        keychainSavedTask?.cancel()
        keychainSavedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.keychainSaved = false
        }
    }

    /// Re-reads API keys from the Keychain when every profile is currently missing one.
    /// A login-item launch before the first unlock of a boot reads an empty Keychain;
    /// once the system unlocks, the session observer calls this so the keys appear
    /// without a restart. Existing (typed-but-unsaved) keys win; preview mode never
    /// touches the Keychain.
    func reloadKeysIfMissing() {
        guard !isPreview, !isConfigured else { return }
        retryLoadKeys()
    }

    /// Reads the Keychain again and backfills any missing keys. Separate from
    /// `reloadKeysIfMissing` so the settings page can offer an explicit retry after a
    /// locked or denied read — that button has to work even once one slot happens to be
    /// filled in, which is exactly the case `reloadKeysIfMissing` skips.
    func retryLoadKeys() {
        guard !isPreview else { return }
        let keys: [Int: String]
        do {
            keys = try Keychain.migrateLegacyKeysIfNeeded() ?? Keychain.loadKeys()
        } catch {
            keychainError = error.localizedDescription
            keychainErrorIsRetryable = Self.isRetryableKeychainFailure(error)
            Log.keychain.error("keychain reload failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // The read went through: whatever the earlier failure was, it no longer
        // describes reality, and leaving the notice up would report a locked Keychain
        // to a user who has since unlocked it.
        keychainError = nil
        keychainErrorIsRetryable = false
        guard !keys.isEmpty else { return }
        for (index, profile) in profiles.enumerated() {
            // Only backfill remote profiles: a loopback (local) profile has no key by
            // design, and a stale key from an earlier remote configuration of the same
            // slot must not be resurrected into it.
            guard profile.config.requiresAuth else { continue }
            if profile.apiKey.isEmpty, let key = keys[index], !key.isEmpty {
                profiles[index].apiKey = key
            }
        }
    }

    /// Flushes debounced profile and Keychain writes before the app exits.
    func flushPendingSaves() {
        profileSaveTask?.cancel()
        profileSaveTask = nil
        if let profiles = pendingProfiles {
            saveProfiles(profiles)
        }

        keychainSaveTask?.cancel()
        keychainSaveTask = nil
        keychainSavedTask?.cancel()
        keychainSavedTask = nil
        if let keys = pendingKeychainKeys {
            saveKeychain(keys)
        }
    }

    /// Shuts the shared sound player down at app termination. Called from
    /// `applicationWillTerminate` after `flushPendingSaves` so the last-written
    /// preferences are already persisted when audio stops.
    func shutdownSound() {
        SoundPlayer.shared.destroy()
    }

    // MARK: - Resolution

    var fallbackIndex: Int { primaryIndex == 0 ? 1 : 0 }

    /// Whether the automatic primary/backup pair has anything usable — deliberately
    /// excludes the local-model slot, since filling in only that slot leaves ordinary
    /// ⏎-to-translate still unconfigured (the local slot is manual-only).
    var isConfigured: Bool { profiles[0].isUsable || profiles[1].isUsable }

    /// Slots to try, in order: primary first, then the fallback if enabled and filled in.
    /// Unusable slots are skipped so a half-filled backup never breaks a working primary.
    var resolvedChain: [(index: Int, config: APIConfig)] {
        var chain: [(Int, APIConfig)] = []
        if profiles[primaryIndex].isUsable {
            chain.append((primaryIndex, profiles[primaryIndex].config))
        }
        if fallbackEnabled, profiles[fallbackIndex].isUsable {
            chain.append((fallbackIndex, profiles[fallbackIndex].config))
        }
        return chain
    }

    /// Slot label for the tabs: the provider's short name (e.g. "deepseek",
    /// "commandcode") rather than the full host — the tabs now share the row equally
    /// (see SettingsView.slotTab), so a full domain like "api.commandcode.ai" ate a
    /// disproportionate share of a tab that also has to fit a role label and dot.
    func label(for index: Int) -> String {
        let host = profiles[index].config.displayHost
        guard !host.isEmpty else { return L("未配置") }
        let short = Self.shortHostName(host)
        guard short.count > 16 else { return short }
        return short.prefix(9) + "…" + short.suffix(6)
    }

    /// Strips the common "api."/"www." subdomain and the trailing TLD from a host,
    /// leaving just the brand: "api.deepseek.com" → "deepseek",
    /// "openrouter.ai" → "openrouter". IPs and single-label hosts (localhost, a bare
    /// LAN address) have no such structure and are returned unchanged.
    private static func shortHostName(_ host: String) -> String {
        var parts = host.split(separator: ".").map(String.init)
        guard parts.count > 1, !parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return host
        }
        let genericPrefixes: Set<String> = ["api", "www", "app"]
        if parts.count > 2, let first = parts.first, genericPrefixes.contains(first.lowercased()) {
            parts.removeFirst()
        }
        if parts.count > 1 {
            parts.removeLast()
        }
        return parts.joined(separator: ".")
    }
}
