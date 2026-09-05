import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    // Not private: PreviewSupport.swift's debug scenarios drive these directly.
    var panelController: PanelController!
    var cancellables = Set<AnyCancellable>()
    private var hotkey: HotkeyManager?
    private var sessionObserver: NSObjectProtocol?

    let settings = SettingsStore()
    let panelState = PanelState()
    lazy var updateChecker = UpdateChecker(preview: settings.isPreview)
    lazy var engine = TranslationEngine(settings: settings)

    func applicationWillTerminate(_ notification: Notification) {
        engine.flushPendingDraftSave()
        settings.flushPendingSaves()
        // Shut the sound engine down: stop loops, silence anything in flight, release
        // cached players (uisfx `ui.destroy()` equivalent for the native player).
        settings.shutdownSound()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One launch line per run: version, preview mode, config state — enough to
        // tell "did it even start" and "was it set up" apart in the unified log.
        // (Locals, not self-access in interpolation: Logger's message is an
        // autoclosure, and `\(self.settings...)` inside it needs explicit self.)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let isPreview = settings.isPreview
        let configured = settings.isConfigured
        Log.app.debug("Tusi \(version) launched (preview=\(isPreview), configured=\(configured))")
        setupMainMenu()
        setupStatusItem()
        panelController = PanelController(
            engine: engine,
            settings: settings,
            panelState: panelState,
            updateChecker: updateChecker,
            statusItem: statusItem
        )
        hotkey = HotkeyManager { [weak self] in
            // The HotkeyManager already hops the Carbon callback to the main queue
            // before invoking this closure, so it is safe to assume main-actor
            // isolation here (Swift 6 requires the explicit assertion).
            MainActor.assumeIsolated {
                self?.togglePanel()
            }
        }
        registerSummonHotkey(settings.shortcut(.summon))

        // A login-item launch before the first unlock of a boot reads an empty
        // Keychain. Re-read the keys once the system unlocks so they appear
        // without a restart, even if the local model already works. The store retries
        // only an unknown credential snapshot or a pending write.
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settings.reloadKeysIfMissing()
            }
        }

        // Re-register whenever the user rebinds or unbinds the summon shortcut. Other
        // shortcut changes flow through here too but are no-ops (same combo → deduped).
        let settingsStore = settings
        Publishers.CombineLatest(settingsStore.$shortcuts, settingsStore.$disabledShortcuts)
            .map { shortcuts, disabled in
                SettingsStore.shortcut(.summon, shortcuts: shortcuts, disabled: disabled)
            }
            .removeDuplicates()
            .dropFirst()
            // Finish the property write before a rejected registration rolls it back.
            .receive(on: RunLoop.main)
            .sink { [weak self] combo in self?.registerSummonHotkey(combo) }
            .store(in: &cancellables)

        // The status menu is rebuilt on every right-click, so a found update surfaces
        // there passively next time it's opened — no push needed.
        updateChecker.setAutomaticChecking(settings.autoCheckUpdates)
        settings.$autoCheckUpdates.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] enabled in self?.updateChecker.setAutomaticChecking(enabled) }
            .store(in: &cancellables)

        // First run without a usable profile: open the panel so setup is obvious.
        if !settings.isConfigured {
            panelController.show()
        }

        // Debug preview: TUSI_PREVIEW=main|settings pins the panel open with sample content.
        configurePreviewIfNeeded()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // `translate` is an SF Symbols 6 / macOS 15 symbol; on macOS 13–14 it's nil
            // and we fall back to the filled speech bubble (the hollow one looked too faint
            // in the menu bar).
            let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Tusi")
                ?? NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: "Tusi")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return togglePanel() }
        if event.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        guard Self.shouldTogglePanel(for: event) else { return }
        togglePanel()
    }

    /// A double-click fires the action twice (clickCount 1 then 2). Toggling on both
    /// would open-and-close the panel in a flash, and ordering the just-activated
    /// panel out that fast makes macOS hand activation back to the previously
    /// frontmost app — which is what made a fast double-click look like it was
    /// opening Telegram. Only the first click of a double-click toggles.
    static func shouldTogglePanel(for event: NSEvent) -> Bool {
        event.clickCount < 2
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        // An available update surfaces at the top, so it's discoverable without opening
        // Settings. The menu is rebuilt on each right-click, so this stays current.
        // While a check is in flight the item is hidden — showing the last known update
        // mid-refresh reads as stale. On failure the previous known update still shows
        // (it remains true that it exists).
        if updateChecker.state != .checking, let update = updateChecker.pendingUpdate {
            let item = NSMenuItem(
                title: String(format: L("有新版本 %@ →"), update.version),
                action: #selector(openUpdatePage),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // No keyEquivalent hint here — the summon shortcut is user-configurable, and a
        // fixed ⌥Space label would just be wrong. Settings shows the real binding.
        let openItem = NSMenuItem(title: L("打开翻译面板"), action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: L("设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出 Tusi"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() {
        panelController.show()
    }

    @objc private func openSettings() {
        panelState.showSettings = true
        panelController.show()
    }

    @objc private func openUpdatePage() {
        if let url = updateChecker.pendingUpdate?.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func togglePanel() {
        panelController.toggle()
    }

    /// Registers (or re-registers) the global summon hotkey and surfaces failure. A nil
    /// manager or a rejected combo means the menu-bar icon is the only way in — a note,
    /// not a fatal error. A nil combo (shortcut unbound) unregisters the hotkey.
    private func registerSummonHotkey(_ combo: KeyCombo?) {
        guard let combo else {
            hotkey?.clear()
            panelState.globalHotkeyFailed = false
            return
        }
        let previousCombo = hotkey?.currentCombo
        let ok = hotkey?.update(combo: combo) ?? false
        if !ok, let previousCombo, settings.shortcut(.summon) != previousCombo {
            // The Carbon registration is the source of truth. If the new combo is
            // rejected, keep Settings aligned with the combo HotkeyManager restored.
            settings.setShortcut(previousCombo, for: .summon)
        }
        panelState.globalHotkeyFailed = !ok
    }

    // MARK: - Main menu (needed so ⌘C/⌘V/⌘Z work in a menu-bar-only app)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("退出 Tusi"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: L("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
