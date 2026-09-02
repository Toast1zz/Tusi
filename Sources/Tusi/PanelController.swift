import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that can receive keyboard input.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    // On `Theme.panelMinWidth` (470): that number covers Chinese, whose bottom bar needs
    // 461.5pt including margins — but NOT English, which measures 523.5pt (the tone labels
    // Casual/Standard/Formal and "Copy" are all wider than 口语/标准/正式 and 复制). An
    // earlier note here credited 428.5pt to English; that was the Chinese figure, and it
    // is why 470 still clipped. Rather than raise the constant for every user to suit the
    // widest localisation, the content now reports what it needs (`PanelContentWidthKey`)
    // and `contentMinWidth` widens the window to match, so 470 is a floor, not a promise.

    private let panel: FloatingPanel
    private let engine: TranslationEngine
    private let settings: SettingsStore
    private let panelState: PanelState
    private let updateChecker: UpdateChecker
    private weak var statusItem: NSStatusItem?

    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var historyResizeTask: Task<Void, Never>?
    private var followsAnimatedHistoryHeight = false
    private var desiredHeight: CGFloat = 160

    /// The narrowest the content can be drawn without clipping, reported by the view via
    /// `PanelContentWidthKey`. Distinct from `settings.panelWidth`, which is the width the
    /// *user* chose: the effective width is the larger of the two, so a wider localisation
    /// widens the window instead of squeezing the controls against a fixed frame.
    private var contentMinWidth: CGFloat = Theme.panelMinWidth

    /// The width the panel should actually use: the user's preference, never narrower than
    /// the content needs, never outside the design bounds.
    private var effectiveWidth: CGFloat {
        min(max(settings.panelWidth, contentMinWidth), Theme.panelMaxWidth)
    }
    private var hasShownOnce = false

    static func clampedPanelHeight(desired: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        let lowerBound: CGFloat = 100
        let upperBound = max(lowerBound, visibleHeight - 12)
        return min(max(desired, lowerBound), upperBound)
    }

    static func shouldAnimateHeightChange(
        isTranslating: Bool,
        reduceMotion: Bool,
        followsAnimatedSwiftUILayout: Bool
    ) -> Bool {
        !isTranslating && !reduceMotion && !followsAnimatedSwiftUILayout
    }

    init(engine: TranslationEngine, settings: SettingsStore, panelState: PanelState, updateChecker: UpdateChecker, statusItem: NSStatusItem?) {
        self.engine = engine
        self.settings = settings
        self.panelState = panelState
        self.updateChecker = updateChecker
        self.statusItem = statusItem

        let width = min(max(settings.panelWidth, Theme.panelMinWidth), Theme.panelMaxWidth)
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
        panel.minSize = NSSize(width: Theme.panelMinWidth, height: 100)
        panel.maxSize = NSSize(width: Theme.panelMaxWidth, height: 2000)
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
        }, onContentMinWidthChange: { [weak self] width in
            self?.setContentMinWidth(width)
        })
        .environmentObject(engine)
        .environmentObject(settings)
        .environmentObject(panelState)
        .environmentObject(updateChecker)

        let container = PanelContainerView(cornerRadius: Theme.panelCornerRadius)
        container.frame = panel.contentRect(forFrameRect: panel.frame)
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        installKeyMonitor()
        installResignObserver()

        // SwiftUI already interpolates the translator's natural height while history
        // folds and unfolds. Follow those measured frames directly; starting a fresh
        // AppKit animation for every intermediate measurement makes the window chase
        // the content and produces visible expand/collapse jitter.
        panelState.$showHistory
            .dropFirst()
            .sink { [weak self] _ in
                self?.beginFollowingAnimatedHistoryHeight()
            }
            .store(in: &cancellables)
    }
    /// `@MainActor deinit` (Swift 5.10+): the deinit runs on the main actor, so it can
    /// safely access the main-actor-isolated `keyMonitor`/`resignObserver` properties.
    /// This is required for Swift 6 language mode, which otherwise rejects touching
    /// actor-isolated state from a nonisolated deinit. AppKit observers are removed
    /// here because the panel's monitors must be torn down with it.
    @MainActor
    deinit {
        historyResizeTask?.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    private func beginFollowingAnimatedHistoryHeight() {
        historyResizeTask?.cancel()
        followsAnimatedHistoryHeight = true
        historyResizeTask = Task { @MainActor [weak self] in
            // Keep one display-frame-sized tail so the final GeometryReader preference
            // cannot arrive just after the SwiftUI duration and start a tiny second hop.
            let duration = Theme.historyTransitionDuration * Theme.animationScale + 0.05
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.followsAnimatedHistoryHeight = false
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
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Reduce Motion skips the fade-in entirely rather than just speeding it up —
        // this is the app's most frequent animation (summoned constantly, via a global
        // hotkey), and a user who turned the setting on wants the panel there
        // immediately, not a still-perceptible cross-fade every single time.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            panel.animator().alphaValue = 1
        }

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
        let width = effectiveWidth

        // Show on the screen the user is actually on (where the mouse is),
        // top-centered just below the menu bar — Spotlight-style. This stays
        // correct even when the status icon is hidden by a crowded menu bar.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let height = Self.clampedPanelHeight(desired: desiredHeight, visibleHeight: visible.height)
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

    /// Called by SwiftUI whenever the content reports a new natural width. Widens the
    /// panel (and raises the drag minimum) so no localisation can be clipped; never
    /// narrows below what the user picked, and never past the design maximum.
    private func setContentMinWidth(_ width: CGFloat) {
        let needed = min(max(width, Theme.panelMinWidth), Theme.panelMaxWidth)
        guard abs(needed - contentMinWidth) > 0.5 else { return }
        contentMinWidth = needed
        // AppKit enforces this during a live drag, so the user cannot pull the panel
        // narrower than its own controls.
        panel.minSize = NSSize(width: needed, height: 100)

        let target = effectiveWidth
        guard abs(target - panelState.panelWidth) > 0.5 else { return }
        panelState.panelWidth = target
        guard panel.isVisible else { return }
        // Keep the top edge and re-clamp horizontally: growing a panel that sits near a
        // screen edge must not push it off the visible area.
        var frame = panel.frame
        frame.origin.y = frame.maxY - frame.height
        frame.size.width = target
        if let visible = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - target - 8)
        }
        panel.setFrame(frame, display: true)
    }

    /// Called by SwiftUI whenever the measured content height changes.
    /// Keeps the top edge anchored so the panel grows downward.
    private func setContentHeight(_ height: CGFloat) {
        var clamped = max(height, 100)
        // A tall result (many lines) plus a small screen (a compact external display,
        // a projector) could otherwise push the panel's bottom edge off the visible
        // area — `panel.maxSize` alone (2000pt) doesn't know about the actual screen.
        if let screenHeight = panel.screen?.visibleFrame.height {
            clamped = Self.clampedPanelHeight(desired: clamped, visibleHeight: screenHeight)
        }
        guard abs(clamped - desiredHeight) > 0.5 else { return }
        desiredHeight = clamped

        guard panel.isVisible else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = clamped
        frame.origin.y = top - clamped

        // While a translation streams, line growth arrives in a rapid burst: a full
        // animated resize per line would stack dozens of overlapping animations and
        // lag the text. Set the frame directly during streaming (the engine already
        // coalesces updates to ~30/s); the eased animation is reserved for discrete
        // layout jumps (history toggle, fold/unfold, mode switch). Reduce Motion
        // collapses it to an instant resize too — this app resizes the panel
        // constantly, and animating through that setting is a standing annoyance, not
        // a nicety.
        //
        // For a single final-height jump, duration/timingFunction come from the same
        // curve as SwiftUI's `Theme.layoutChange`. History is different: SwiftUI emits
        // the intermediate heights itself, so the window follows them directly instead
        // of easing each already-eased frame a second time.
        let shouldAnimate = Self.shouldAnimateHeightChange(
            isTranslating: engine.isTranslating,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            followsAnimatedSwiftUILayout: followsAnimatedHistoryHeight
        )
        if !shouldAnimate {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.layoutChangeDuration * Theme.animationScale
                context.timingFunction = Theme.caTimingFunction
                panel.animator().setFrame(frame, display: true)
            }
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
                    self.panelState.pendingBareShortcut = nil
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
            // Shortcuts → Settings → Translator → hide. Backing out of a page matches
            // the on-screen back buttons (back cue); hiding the panel stays silent so
            // the frequent Esc-to-dismiss doesn't get noisy.
            if let combo = self.settings.shortcut(.close), combo.matches(event) {
                if self.panelState.showShortcuts {
                    withAnimation(Theme.pageTransition) { self.panelState.showShortcuts = false }
                } else if self.panelState.showSettings {
                    withAnimation(Theme.pageTransition) { self.panelState.showSettings = false }
                } else {
                    self.hide()
                }
                return nil
            }

            // ⌘, opens settings (not user-configurable — a macOS convention).
            if flags == .command, event.charactersIgnoringModifiers == "," {
                withAnimation(Theme.pageTransition) { self.panelState.showSettings = true }
                return nil
            }

            // Let text fields in settings behave normally.
            guard !self.panelState.showSettings else { return event }

            if let combo = self.settings.shortcut(.copy), combo.matches(event) {
                self.engine.copyOutput()
                return nil
            }
            if let combo = self.settings.shortcut(.newline), combo.matches(event) {
                // AppKit won't treat a modified Return as a newline on its own; ask the
                // focused text view directly so the cursor and undo stack stay intact.
                (self.panel.firstResponder as? NSTextView)?.insertNewline(nil)
                return nil
            }
            if let combo = self.settings.shortcut(.translate), combo.matches(event) {
                self.engine.translate()
                return nil
            }
            // Anything else (e.g. ⇧Return) falls through to the text view, which inserts
            // a newline by default — so ⇧Return keeps working without special-casing.
            return event
        }
    }

    /// Whether a recorded combo would consume a character the user still needs for
    /// typing, and therefore has to be confirmed rather than bound on the spot. Only
    /// modifier-less letters and digits qualify: Return, Esc and the arrow keys are not
    /// characters anyone types into the input box, and the global hotkey already refuses
    /// bare keys outright. Static and pure so the rule can be tested without an NSEvent.
    static func needsBareKeyConfirmation(action: ShortcutAction, modifiers: UInt, characters: String?) -> Bool {
        guard !action.requiresModifier, modifiers == 0, let characters else { return false }
        return characters.rangeOfCharacter(from: .alphanumerics) != nil
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
            $0 != action && (settings.shortcut($0).map { KeyCombo.sameKey($0, combo) } ?? false)
        }) {
            panelState.shortcutError = String(format: L("与「%@」重复了"), clash.label)
            return
        }

        panelState.recordingShortcut = nil
        panelState.shortcutError = nil
        // A bare letter/digit shortcut takes that character away from typing — inside
        // the panel, the input box is exactly where it would have been typed. That is
        // worth a second yes rather than a notice under an already-applied binding: hold
        // it, explain it, and let the user decide (see PanelState.pendingBareShortcut).
        if Self.needsBareKeyConfirmation(
            action: action,
            modifiers: combo.modifiers,
            characters: event.charactersIgnoringModifiers
        ) {
            panelState.pendingBareShortcut = PanelState.PendingShortcut(action: action, combo: combo)
            return
        }
        panelState.pendingBareShortcut = nil
        settings.setShortcut(combo, for: action)
    }

    private func installResignObserver() {
        // queue: .main is load-bearing — the closure relies on MainActor.assumeIsolated
        // below. Changing the queue to a background one would crash instead of degrade.
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
            // `contentMinWidth`, not `Theme.panelMinWidth`: the floor is whatever the
            // content actually needs, so a drag can't reintroduce the clipping.
            width: min(max(frameSize.width, contentMinWidth), Theme.panelMaxWidth),
            height: desiredHeight
        )
    }

    func windowDidResize(_ notification: Notification) {
        let width = min(max(panel.frame.width, contentMinWidth), Theme.panelMaxWidth)
        guard abs(width - panelState.panelWidth) > 0.5 else { return }
        // Live-updates the UI binding every tick of the drag, but does NOT persist —
        // `settings.panelWidth`'s didSet writes UserDefaults synchronously, and a drag
        // fires this dozens of times. Persisting happens once, in
        // `windowDidEndLiveResize`, when the user actually settles on a width.
        panelState.panelWidth = width
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        settings.panelWidth = panelState.panelWidth
    }
}
