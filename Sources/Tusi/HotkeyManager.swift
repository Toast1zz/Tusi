import AppKit
import Carbon

/// Registers a user-chosen combo as a global hotkey via Carbon (no accessibility
/// permission needed). The event handler is installed once at init; the hotkey itself can
/// be re-registered at any time via `update(combo:)` when the user rebinds it.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// The combo currently registered, so a failed re-registration can roll back to it.
    private var registeredCombo: KeyCombo?
    var currentCombo: KeyCombo? { registeredCombo }
    /// The callback is `@Sendable` so it can be captured by the Carbon event handler
    /// (which fires on an arbitrary thread) and safely hop to the main actor. It is
    /// immutable after init, so capturing it in the handler is race-free.
    private let callback: @Sendable () -> Void

    /// Fails only if the Carbon event handler can't be installed (rare). The hotkey
    /// registration itself is done separately via `update(combo:)`, which is retryable.
    init?(callback: @escaping @Sendable () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                // Carbon fires on a background thread; hop to main where the UI lives.
                // `callback` is @Sendable and immutable, so this capture is safe.
                let callback = manager.callback
                DispatchQueue.main.async { callback() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installStatus == noErr else { return nil }
        handlerRef = handler
    }

    /// (Re)registers the global hotkey. Returns whether registration succeeded — a bare
    /// combo (no modifier) is rejected, as are combos another app already owns. On
    /// failure the previously registered combo (if any) is re-registered, so a rejected
    /// rebind never silently kills the working hotkey.
    @discardableResult
    func update(combo: KeyCombo) -> Bool {
        let previousCombo = registeredCombo
        unregisterCurrent()

        let carbonMods = Self.carbonModifiers(from: combo.modifiers)
        guard carbonMods != 0 else { return restore(previousCombo) }

        let hotKeyID = EventHotKeyID(signature: Self.fourCC("TUSI"), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            carbonMods,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr else { return restore(previousCombo) }
        hotKeyRef = ref
        registeredCombo = combo
        return true
    }

    /// Unregisters the global hotkey entirely (shortcut unbound).
    func clear() {
        unregisterCurrent()
    }

    private func unregisterCurrent() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredCombo = nil
    }

    /// Tries to put the previous combo back after a failed update. Returns false either
    /// way — the new combo was rejected regardless — but restores the old hotkey when
    /// the system still accepts it.
    private func restore(_ combo: KeyCombo?) -> Bool {
        guard let combo else { return false }
        let hotKeyID = EventHotKeyID(signature: Self.fourCC("TUSI"), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            Self.carbonModifiers(from: combo.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            registeredCombo = combo
        }
        return false
    }

    // Carbon's event handler can fire on any thread, and there's a theoretical window
    // between that callback running and `deinit` removing the handler. This is safe in
    // practice only because this object lives exactly as long as the app (owned by
    // AppDelegate, never recreated mid-session) — it must not be freed early for some
    // other refactor's convenience, or that window becomes real.
    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private static func carbonModifiers(from raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    private static func fourCC(_ string: String) -> FourCharCode {
        string.utf16.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}
