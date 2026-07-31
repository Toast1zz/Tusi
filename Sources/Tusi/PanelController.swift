import AppKit
import SwiftUI

/// Borderless floating panel that can receive keyboard input.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    // 424 was sized for the Chinese bottom bar; English tone labels (Casual/Standard/
    // Formal vs 口语/标准/正式) measured 428.5pt of *content* alone in that row, which
    // overflows 424 once its 16pt side margins are added. 470 clears that with room
    // to spare in both languages.

    private let panel: FloatingPanel
    private let engine: TranslationEngine
    private let settings: SettingsStore
    private let panelState: PanelState
    private let updateChecker: UpdateChecker
    private weak var statusItem: NSStatusItem?

    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var desiredHeight: CGFloat = 160
    private var hasShownOnce = false

    init(engine: TranslationEngine, settings: SettingsStore, panelState: PanelState, updateChecker: UpdateChecker, statusItem: NSStatusItem?) {
        self.engine = engine
        self.settings = settings
        self.panelState = panelState
        self.updateChecker = updateChecker
        self.statusItem = statusItem

        let width = min(max(settings.panelWidth, 470), 700)
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        settings.panelWidth = width
        panelState.panelWidth = width
        panel.delegate = self
        panel.minSize = NSSize(width: 470, height: 100)
        panel.maxSize = NSSize(width: 700, height: 2000)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let root = RootView(onHeightChange: { [weak self] height in
            self?.setContentHeight(height)
        })
        .environmentObject(engine)
        .environmentObject(settings)
        .environmentObject(panelState)
        .environmentObject(updateChecker)

        let container = PanelContainerView(cornerRadius: Theme.cornerRadius)
        container.frame = panel.contentRect(forFrameRect: panel.frame)
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        installKeyMonitor()
        installResignObserver()
    }
    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    // MARK: - Show / hide

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        position()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.animator().alphaValue = 1

        if !hasShownOnce {
            hasShownOnce = true
            if !settings.isConfigured {
                panelState.showSettings = true
            }
        }
        // Reopening on a finished translation means the last text is spent. The view
        // applies focus first, then selects on the next actor turn — no timing constants.
        NotificationCenter.default.post(
            name: .tusiFocusInput,
            object: engine.hasFinishedTranslation
        )
    }

    func hide() {
        guard panel.isVisible else { return }
        // Deliberately NOT NSApp.hide(nil): that call hands activation back to whichever
        // app was frontmost before Tusi took it — exactly like ⌘H — which is what made the
        // *previous* app's window jump forward on the second click (e.g. Telegram). Ordering
        // the panel out is enough; the next real click elsewhere activates that app normally.
        panel.orderOut(nil)
    }

    private func position() {
        let width = settings.panelWidth
        let height = desiredHeight

        // Show on the screen the user is actually on (where the mouse is),
        // top-centered just below the menu bar — Spotlight-style. This stays
        // correct even when the status icon is hidden by a crowded menu bar.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        var x = visible.midX - width / 2

        // If the status icon is visible on this screen, anchor under it instead.
        if let buttonWindow = statusItem?.button?.window,
           buttonWindow.screen == screen,
           screen.frame.intersects(buttonWindow.frame) {
            x = buttonWindow.frame.midX - width / 2
        }
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)

        let y = visible.maxY - 6 - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    /// Called by SwiftUI whenever the measured content height changes.
    /// Keeps the top edge anchored so the panel grows downward.
    private func setContentHeight(_ height: CGFloat) {
        let clamped = max(height, 100)
        guard abs(clamped - desiredHeight) > 0.5 else { return }
        desiredHeight = clamped

        guard panel.isVisible else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = clamped
        frame.origin.y = top - clamped

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25 * Theme.animationScale
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }

            let flags = KeyCombo.normalized(event.modifierFlags)

            // Recording a new shortcut swallows everything until it gets a valid combo.
            if let action = self.panelState.recordingShortcut {
                if event.keyCode == 53 {  // Esc always cancels recording.
                    self.panelState.recordingShortcut = nil
                    self.panelState.shortcutError = nil
                    return nil
                }
                self.captureShortcut(for: action, event: event, flags: flags)
                return nil
            }

            // While an input method is composing marked text, Return commits the
            // candidate and Esc cancels it. Those events must reach NSTextView before
            // panel shortcuts get a chance to consume them.
            if (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true {
                return event
            }

            // Close / back — configurable (default Esc). Backs out one level at a time:
            // Shortcuts → Settings → Translator → hide.
            if self.settings.shortcut(.close).matches(event) {
                if self.panelState.showShortcuts {
                    withAnimation(.snappy(duration: 0.25)) { self.panelState.showShortcuts = false }
                } else if self.panelState.showSettings {
                    withAnimation(.snappy(duration: 0.25)) { self.panelState.showSettings = false }
                } else {
                    self.hide()
                }
                return nil
            }

            // ⌘, opens settings (not user-configurable — a macOS convention).
            if flags == .command, event.charactersIgnoringModifiers == "," {
                withAnimation(.snappy(duration: 0.25)) { self.panelState.showSettings = true }
                return nil
            }

            // Let text fields in settings behave normally.
            guard !self.panelState.showSettings else { return event }

            if self.settings.shortcut(.copy).matches(event) {
                self.engine.copyOutput()
                return nil
            }
            if self.settings.shortcut(.newline).matches(event) {
                // AppKit won't treat a modified Return as a newline on its own; ask the
                // focused text view directly so the cursor and undo stack stay intact.
                (self.panel.firstResponder as? NSTextView)?.insertNewline(nil)
                return nil
            }
            if self.settings.shortcut(.translate).matches(event) {
                self.engine.translate()
                return nil
            }
            // Anything else (e.g. ⇧Return) falls through to the text view, which inserts
            // a newline by default — so ⇧Return keeps working without special-casing.
            return event
        }
    }

    /// Validates a recorded keystroke and, if it passes, binds it to the action. Rejections
    /// (missing modifier for the global key, or a clash with another shortcut) leave
    /// recording active and post a message for Settings to show.
    private func captureShortcut(for action: ShortcutAction, event: NSEvent, flags: NSEvent.ModifierFlags) {
        if action.requiresModifier {
            let hasRealModifier = flags.contains(.command)
                || flags.contains(.control)
                || flags.contains(.option)
            guard hasRealModifier else {
                panelState.shortcutError = L("全局呼出必须包含 ⌘ / ⌃ / ⌥ 修饰键")
                return
            }
        }

        let combo = KeyCombo(
            keyCode: event.keyCode,
            modifiers: flags.rawValue,
            display: KeyCombo.describe(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                flags: flags
            )
        )

        if let clash = ShortcutAction.allCases.first(where: {
            $0 != action && KeyCombo.sameKey(settings.shortcut($0), combo)
        }) {
            panelState.shortcutError = String(format: L("与「%@」重复了"), clash.label)
            return
        }

        settings.setShortcut(combo, for: action)
        panelState.recordingShortcut = nil
        // A bare letter/digit shortcut hijacks that key for typing — warn about it, but
        // keep the binding (the defaults are all safe, and blocking would be worse).
        if !action.requiresModifier, combo.modifiers == 0,
           let chars = event.charactersIgnoringModifiers,
           chars.rangeOfCharacter(from: .alphanumerics) != nil {
            panelState.shortcutError = L("该快捷键没有修饰键，绑定字母或数字后，输入时无法再打出这个字符")
        } else {
            panelState.shortcutError = nil
        }
    }

    private func installResignObserver() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panelState.pinned else { return }
                // If the click landed on the status item, let its action handle the toggle.
                if let button = self.statusItem?.button, let window = button.window,
                   window.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                self.hide()
            }
        }
    }

    // MARK: - Panel resize

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: min(max(frameSize.width, 470), 700),
            height: desiredHeight
        )
    }

    func windowDidResize(_ notification: Notification) {
        let width = min(max(panel.frame.width, 470), 700)
        guard abs(width - panelState.panelWidth) > 0.5 else { return }
        panelState.panelWidth = width
        settings.panelWidth = width
    }
}
