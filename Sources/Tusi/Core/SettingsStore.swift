import Foundation
import Combine
import ServiceManagement

struct APIConfig: Equatable {
    var baseURL: String
    var apiKey: String
    var model: String
    /// Comma/whitespace-separated backend names (e.g. "novita, together") sent as
    /// OpenRouter's `provider.order` routing hint. It is sent only to OpenRouter hosts;
    /// strict gateways must not receive this provider-specific top-level field.
    var providerOrder: String = ""

    var isUsable: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Host of the base URL, used as a display name for the slot ("api.deepseek.com").
    var displayHost: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
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
struct APIProfile: Equatable {
    var baseURL = ""
    var apiKey = ""
    var model = ""
    var providerOrder = ""

    var config: APIConfig {
        APIConfig(baseURL: baseURL, apiKey: apiKey, model: model, providerOrder: providerOrder)
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

    /// Exactly two slots: index 0 and index 1.
    @Published var profiles: [APIProfile] {
        didSet { persistProfiles(previous: oldValue) }
    }

    /// Set when a Keychain write failed. The pending snapshot is retained so a later
    /// edit or application shutdown can retry it instead of silently losing the key.
    @Published private(set) var keychainError: String?

    private var keychainSaveTask: Task<Void, Never>?
    private var pendingKeychainKeys: [Int: String]?
    private var profileSaveTask: Task<Void, Never>?
    private var pendingProfiles: [APIProfile]?

    @Published var panelWidth: CGFloat = 470 {
        didSet { defaults.set(Double(panelWidth), forKey: "panelWidth") }
    }
    @Published var primaryIndex: Int {
        didSet { defaults.set(primaryIndex, forKey: "primaryIndex") }
    }
    @Published var fallbackEnabled: Bool {
        didSet { defaults.set(fallbackEnabled, forKey: "fallbackEnabled") }
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
    /// Master sound volume 0...1. Persisted; applied live to the shared player.
    @Published var soundVolume: Double {
        didSet {
            guard soundVolume != oldValue else { return }
            defaults.set(soundVolume, forKey: "soundVolume")
            SoundPlayer.shared.volume = soundVolume
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
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Reverts silently when not running from a proper .app bundle.
                launchAtLogin = oldValue
            }
        }
    }
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
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        tone = Tone(rawValue: defaults.string(forKey: "tone") ?? "") ?? .standard
        multiLanguageMode = defaults.bool(forKey: "multiLanguageMode")
        // Sound preferences: enabled defaults to true (sound is opt-out), volume to 0.7.
        // The player's own defaults must match these so a fresh install behaves the same
        // whether or not the keys exist. The didSet during init already persisted them;
        // the live player sync happens at the end of init (see below) once every stored
        // property is initialized.
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        soundVolume = min(max(defaults.object(forKey: "soundVolume") as? Double ?? 0.7, 0), 1)
        let storedWidth = defaults.double(forKey: "panelWidth")
        if storedWidth > 0 {
            panelWidth = min(max(CGFloat(storedWidth), 470), 700)
        }
        extraInstruction = defaults.string(forKey: "extraInstruction") ?? ""
        shortcuts = Self.loadShortcuts(defaults: defaults)
        disabledShortcuts = Self.loadDisabledShortcuts(defaults: defaults)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        profiles = isPreview ? [APIProfile(), APIProfile()] : Self.loadProfiles(defaults: defaults)

        // Sync the persisted sound preferences into the shared player. Must come after
        // every stored property is initialized (reading `soundEnabled`/`soundVolume`
        // earlier would trip Swift's initialization rules).
        SoundPlayer.shared.enabled = soundEnabled
        SoundPlayer.shared.volume = soundVolume
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

    private static func loadProfiles(defaults: UserDefaults) -> [APIProfile] {
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
        let keys = Keychain.migrateLegacyKeysIfNeeded() ?? Keychain.loadKeys()

        return (0...1).map { index in
            APIProfile(
                baseURL: defaults.string(forKey: "baseURL.\(index)") ?? "",
                apiKey: keys[index] ?? "",
                model: defaults.string(forKey: "model.\(index)") ?? "",
                providerOrder: defaults.string(forKey: "providerOrder.\(index)") ?? ""
            )
        }
    }

    private func persistProfiles(previous: [APIProfile]) {
        guard !isPreview else { return }

        let preferencesChanged = profiles.count != previous.count
            || zip(profiles, previous).contains {
                $0.baseURL != $1.baseURL
                    || $0.model != $1.model
                    || $0.providerOrder != $1.providerOrder
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
        for (index, profile) in profiles.enumerated() {
            defaults.set(profile.baseURL, forKey: "baseURL.\(index)")
            defaults.set(profile.model, forKey: "model.\(index)")
            defaults.set(profile.providerOrder, forKey: "providerOrder.\(index)")
        }
        pendingProfiles = nil
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
        } catch {
            keychainError = error.localizedDescription
        }
    }

    /// Re-reads API keys from the Keychain when every profile is currently missing one.
    /// A login-item launch before the first unlock of a boot reads an empty Keychain;
    /// once the system unlocks, the session observer calls this so the keys appear
    /// without a restart. Existing (typed-but-unsaved) keys win; preview mode never
    /// touches the Keychain.
    func reloadKeysIfMissing() {
        guard !isPreview, !isConfigured else { return }
        let keys = Keychain.migrateLegacyKeysIfNeeded() ?? Keychain.loadKeys()
        guard !keys.isEmpty else { return }
        for (index, profile) in profiles.enumerated() {
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

    var isConfigured: Bool { profiles.contains { $0.isUsable } }

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

    /// Slot label for the tabs. Truncated here rather than with a fixed-width
    /// frame so the tab capsule hugs its text instead of reserving dead space.
    func label(for index: Int) -> String {
        let host = profiles[index].config.displayHost
        guard !host.isEmpty else { return L("未配置") }
        guard host.count > 22 else { return host }
        return host.prefix(11) + "…" + host.suffix(8)
    }
}
