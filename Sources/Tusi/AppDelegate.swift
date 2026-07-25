import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var hotkey: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()

    let settings = SettingsStore()
    let panelState = PanelState()
    let updateChecker = UpdateChecker()
    lazy var engine = TranslationEngine(settings: settings)

    func applicationWillTerminate(_ notification: Notification) {
        settings.flushPendingSaves()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            self?.togglePanel()
        }
        registerSummonHotkey(settings.shortcut(.summon))

        // Re-register whenever the user rebinds the summon shortcut. Other shortcut
        // changes flow through here too but are no-ops (same summon combo → deduped).
        settings.$shortcuts
            .map { $0[.summon] ?? ShortcutAction.summon.defaultCombo }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] combo in self?.registerSummonHotkey(combo) }
            .store(in: &cancellables)

        // The status menu is rebuilt on every right-click, so a found update surfaces
        // there passively next time it's opened — no push needed.
        if settings.autoCheckUpdates {
            updateChecker.check(manual: false)
        }

        // First run without a usable profile: open the panel so setup is obvious.
        if !settings.isConfigured {
            panelController.show()
        }

        // Debug preview: TUSI_PREVIEW=main|settings pins the panel open with sample content.
        if let preview = ProcessInfo.processInfo.environment["TUSI_PREVIEW"] {
            if ProcessInfo.processInfo.environment["TUSI_DARK"] != nil {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            panelState.pinned = true
            panelController.show()
            switch preview {
            case "settings", "update-available", "update-latest", "shortcuts":
                settings.profiles = [
                    APIProfile(baseURL: "https://api.deepseek.com", apiKey: "sk-preview", model: "deepseek-chat"),
                    APIProfile(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-preview", model: "deepseek/deepseek-chat"),
                ]
                panelState.showSettings = true
                if preview == "update-available" {
                    updateChecker.debugSetState(.available(version: "1.3.0", url: URL(string: "https://github.com/neko1chau/Tusi/releases/latest")!))
                } else if preview == "update-latest" {
                    updateChecker.debugSetState(.upToDate)
                } else if preview == "shortcuts" {
                    panelState.showShortcuts = true
                }
            case "empty":
                panelState.showSettings = false
            case "quotetest":
                settings.profiles = [
                    APIProfile(baseURL: "http://127.0.0.1:8806/v1", apiKey: "sk-x", model: "m"),
                    APIProfile(),
                ]
                settings.autoCopy = true
                panelState.showSettings = false
                engine.$history
                    .dropFirst()
                    .first()
                    .sink { [weak self] records in
                        let receipt = "TUSI_HISTORY_COUNT=\(records.count)\n"
                        FileHandle.standardError.write(Data(receipt.utf8))
                        self?.panelState.showHistory = true
                    }
                    .store(in: &cancellables)
                engine.input = "测试引号"
                engine.translate()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    let receipt = "TUSI_STATE=\(self.engine.state) OUTPUT=\(self.engine.output) HISTORY=\(self.engine.history.count)\n"
                    FileHandle.standardError.write(Data(receipt.utf8))
                }
            case "corners":
                // Opens settings on a delay so a screenshot burst can catch the
                // transition mid-flight; pair with TUSI_SLOWMO to stretch it out.
                engine.debugPreview(
                    input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                    output: "Thanks to the brand-new architecture, this update delivers a significant performance boost.",
                    toast: nil
                )
                panelState.showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.snappy(duration: 0.25 * Theme.animationScale)) {
                        self.panelState.showSettings = true
                    }
                }
            case "reopen":
                panelState.showSettings = false
                engine.debugPreview(
                    input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                    output: "Thanks to the brand-new architecture, this update delivers a significant performance boost.",
                    toast: nil
                )
                panelController.show()
            case "falltest":
                // Primary points at a server that 401s, backup at one that works.
                settings.profiles = [
                    APIProfile(baseURL: "http://127.0.0.1:8801/v1", apiKey: "sk-x", model: "broken-model"),
                    APIProfile(baseURL: "http://127.0.0.1:8802/v1", apiKey: "sk-x", model: "backup-model"),
                ]
                panelState.showSettings = false
                engine.input = "这句话应该由备用供应商翻译。"
                engine.translate()
            default:
                panelState.showSettings = false
                engine.debugPreview(
                    input: "得益于全新的架构，这次更新带来了显著的性能提升，同时保持了完全的向后兼容。",
                    output: "Thanks to the brand-new architecture, this update delivers a significant performance boost while remaining fully backward compatible.",
                    toast: preview == "fallback" ? .fellBack : nil
                )
            }
        }
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
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        // An available update surfaces at the top, so it's discoverable without opening
        // Settings. The menu is rebuilt on each right-click, so this stays current.
        if let update = updateChecker.pendingUpdate {
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
    /// not a fatal error.
    private func registerSummonHotkey(_ combo: KeyCombo) {
        let ok = hotkey?.update(combo: combo) ?? false
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
