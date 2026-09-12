import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that can receive keyboard input.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var resizeTask: Task<Void, Never>?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        // Any direct update owns the frame immediately. A previous animation must
        // never write its old destination after an input-size update or a drag.
        resizeTask?.cancel()
        resizeTask = nil
        super.setFrame(frameRect, display: flag)
    }

    func animateFrame(to destination: NSRect) {
        resizeTask?.cancel()
        let start = frame
        resizeTask = Task { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let progress = Theme.windowResizeProgress(elapsed: elapsed)
                let rect = NSRect(x: start.minX + (destination.minX - start.minX) * progress,
                                  y: start.minY + (destination.minY - start.minY) * progress,
                                  width: start.width + (destination.width - start.width) * progress,
                                  height: start.height + (destination.height - start.height) * progress)
                self?.applyAnimationFrame(rect)
                if progress >= 1 { return }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
        }
    }

    private func applyAnimationFrame(_ rect: NSRect) {
        super.setFrame(rect, display: true)
    }

    override func orderOut(_ sender: Any?) {
        resizeTask?.cancel()
        resizeTask = nil
        super.orderOut(sender)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let panel: FloatingPanel
    private let engine: TranslationEngine
    private let settings: SettingsStore
    private let panelState: PanelState
    private let updateChecker: UpdateChecker
    private weak var statusItem: NSStatusItem?

    private var keyMonitor: Any?
    private var returnHold = ReturnHold()
    private var returnHoldTask: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?
    private var desiredHeight: CGFloat = 160

    /// The SwiftUI host, kept so the fit audit can ask AppKit what the content measures
    /// instead of asking the preference chain that may be the thing at fault.
    private var contentHost: NSView?
    /// Debounces the audit to one run per settled resize.
    private var fitAudit: DispatchWorkItem?
    private var contentObservation: AnyCancellable?
    private var pendingShrinkHeight: CGFloat?

    private var emptyResizeTask: Task<Void, Never>?

    /// The width the panel should actually use: the user's preference, inside the design
    /// bounds. The bottom bar no longer grows with state or language, so the content never
    /// needs to push it wider.
    private var effectiveWidth: CGFloat {
        min(max(settings.panelWidth, Theme.panelMinWidth), Theme.panelMaxWidth)
    }
    private var hasShownOnce = false

    /// The floor under the panel's height. Its only job is to reject a nonsense
    /// measurement (a view mid-teardown reporting nothing), so it has to sit *below* the
    /// smallest height the panel legitimately wants — which is an empty one-line input
    /// plus the bottom bar, measured at 86pt. The floor used to be 100pt: taller than
    /// the real thing, so the emptiest state of the panel was padded by 14pt of nothing.
    /// Split evenly above and below the content that read as slightly loose spacing;
    /// once content was anchored to the top it read as the bottom bar sitting too high,
    /// which is what it had always been.
    static let minimumPanelHeight: CGFloat = 60

    static func clampedPanelHeight(desired: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        let upperBound = max(minimumPanelHeight, visibleHeight - 12)
        return min(max(desired, minimumPanelHeight), upperBound)
    }

    /// Whether the window has to move for a content height of `target`.
    ///
    /// `actual` is the window's own height — never the last height this controller
    /// *asked* for. The two come apart whenever a resize does not land (an animation
    /// interrupted by a panel drag, a frame set while the panel was ordered out), and an
    /// intent-against-intent comparison discards precisely the report that would put
    /// them back together, leaving the panel wrong until the content height happens to
    /// change again.
    static func heightNeedsApply(actual: CGFloat, target: CGFloat) -> Bool {
        abs(actual - target) > 0.5
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
        panel.minSize = NSSize(width: Theme.panelMinWidth, height: Self.minimumPanelHeight)
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
        })
        .environmentObject(engine)
        .environmentObject(settings)
        .environmentObject(panelState)
        .environmentObject(updateChecker)
        // NSHostingView centres a root view shorter than its bounds, which turns any
        // window/content height mismatch into padding (or clipping) split evenly across
        // the top and bottom edges. The panel is anchored at its top edge everywhere
        // else — `position()`, `applyHeight` — so anchor the content there too: slack
        // then collects harmlessly at the bottom instead of eating the input's padding.
        //
        // `minHeight: 0` is what makes that hold in the other direction. With only
        // `maxHeight`, the frame grows to its content whenever the content is the taller
        // one — which it briefly is at the start of every expansion, because the view's
        // height lands a layout pass before the window's — and NSHostingView then centres
        // the oversized root, pushing the input up by half the difference and dropping
        // back as the window catches up. Measured at 43pt when opening history. Pinned to
        // exactly the window's height, the overflow is only ever clipped at the bottom.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)

        let container = PanelContainerView(cornerRadius: Theme.panelCornerRadius)
        container.frame = panel.contentRect(forFrameRect: panel.frame)
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.installContent(hosting)
        panel.contentView = container
        contentHost = hosting

        // Content can change without SwiftUI delivering a new height preference.
        // Observe the model independently so a lost report still gets a settled audit.
        contentObservation = engine.objectWillChange.sink { [weak self] in
            self?.scheduleFitAudit()
        }

        installKeyMonitor()
        installResignObserver()

    }
    /// `@MainActor deinit` (Swift 5.10+): the deinit runs on the main actor, so it can
    /// safely access the main-actor-isolated `keyMonitor`/`resignObserver` properties.
    /// This is required for Swift 6 language mode, which otherwise rejects touching
    /// actor-isolated state from a nonisolated deinit. AppKit observers are removed
    /// here because the panel's monitors must be torn down with it.
    @MainActor
    deinit {
        emptyResizeTask?.cancel()
        returnHoldTask?.cancel()
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
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The one animation in the app that cannot go through `.motion`: `alphaValue`
        // belongs to the window, not to any view. It is still driven by Theme's curve
        // and duration so the summon shares the app's motion character.
        //
        // `hide()` has no counterpart on purpose: a summon should feel like the panel
        // was already there, a dismissal like it is already gone. Fading out would put
        // a translucent panel over whatever the user just turned back to look at.
        //
        // Reduce Motion skips the fade entirely rather than shortening it — this is the
        // app's most frequent animation (⌥Space, dozens of times a day), and a user who
        // turned the setting on wants the panel there, not a brief cross-fade every
        // single time. Read from NSWorkspace rather than the environment because there
        // is no SwiftUI view here to read one from.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            // motion-exception: the window's own alphaValue, which no SwiftUI view owns.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.panelAppearDuration * Theme.animationScale
                context.timingFunction = Theme.caTimingFunction
                panel.animator().alphaValue = 1
            }
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
        emptyResizeTask?.cancel()
        cancelReturnHold()
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
        panelState.availableHeight = visible.height - 12
        // Write the clamp back: `windowWillResize` pins every non-animated resize to
        // `desiredHeight`, so a clamp that only lives in this local would be undone by
        // the delegate on the very `setFrame` below.
        let height = Self.clampedPanelHeight(desired: desiredHeight, visibleHeight: visible.height)
        desiredHeight = height
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
    func setContentHeight(_ height: CGFloat) {
        var clamped = max(height, Self.minimumPanelHeight)
        // A tall result (many lines) plus a small screen (a compact external display,
        // a projector) could otherwise push the panel's bottom edge off the visible
        // area — `panel.maxSize` alone (2000pt) doesn't know about the actual screen.
        if let screenHeight = panel.screen?.visibleFrame.height {
            clamped = Self.clampedPanelHeight(desired: clamped, visibleHeight: screenHeight)
        }
        clamped = ceil(clamped)
        let destinationChanged = Self.heightNeedsApply(actual: desiredHeight, target: clamped)
        desiredHeight = clamped
        if isEmptyTranslator && panel.isVisible {
            scheduleEmptyResize()
            return
        }
        emptyResizeTask?.cancel()
        // Content can re-report the same destination during a native resize. Do
        // not restart that animation while its presentation frame is still moving.
        if panelState.showSettings && !destinationChanged { return }
        guard panel.isVisible else { return }
        applyHeight(clamped)
        scheduleFitAudit()
    }

    private var isEmptyTranslator: Bool {
        engine.input.isEmpty && engine.output.isEmpty && !panelState.showSettings && !panelState.showHistory
    }

    /// Width and height are separate SwiftUI preferences. Gather both from the
    /// clearing layout before starting one native frame transition. Never apply
    /// the width with a stale multi-line/result height in the meantime.
    private func scheduleEmptyResize() {
        fitAudit?.cancel()
        emptyResizeTask?.cancel()
        emptyResizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, self.isEmptyTranslator, self.panel.isVisible else { return }
            self.panelState.inputResizeInProgress = false
            var target = Self.emptyResizeFrame(current: self.panel.frame,
                                               width: self.effectiveWidth, height: self.desiredHeight)
            if let visible = self.panel.screen?.visibleFrame {
                target.origin.x = min(max(target.origin.x, visible.minX + 8), visible.maxX - target.width - 8)
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.panel.setFrame(target, display: true)
            } else {
                Self.animateResize(self.panel, to: target)
            }
            self.scheduleFitAudit()
        }
    }

    static func emptyResizeFrame(current: NSRect, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: current.midX - width / 2, y: current.maxY - ceil(height), width: width, height: ceil(height))
    }

    /// Checks, once the dust has settled, that the window is actually the size its
    /// content needs — measured independently of the chain that reported the height.
    ///
    /// Every hop from the result text to this window is a preference feeding a `@State`
    /// that sets the next hop's frame, and SwiftUI does not promise to redeliver a
    /// preference for the layout its own state write caused. A link that goes quiet
    /// cannot report that it went quiet; the window simply keeps the height it had while
    /// the content grows past the bottom edge, taking the bottom bar with it. `fittingSize`
    /// asks AppKit what the hosted content measures right now, which is the one question
    /// a missing preference cannot corrupt.
    ///
    /// Delayed past `windowResizeDuration` so it audits the settled state rather than
    /// racing the resize it was scheduled by, and debounced so a streaming translation
    /// runs it once at the end instead of once per chunk.
    private func scheduleFitAudit(confirmingShrink: Bool = false) {
        fitAudit?.cancel()
        if !confirmingShrink { pendingShrinkHeight = nil }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Order matters: land the resize that was already asked for, then ask
                // whether what landed actually fits. Auditing first would measure a
                // window still in mid-animation and report a mismatch that was about to
                // resolve itself.
                self.verifyHeightLanded()
                self.auditContentFit()
            }
        }
        fitAudit = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (confirmingShrink ? 0.06 : Theme.windowResizeDuration * Theme.animationScale + 0.12),
            execute: work
        )
    }

    private func auditContentFit() {
        guard panel.isVisible, let contentHost else { return }
        guard !panelState.inputResizeInProgress else {
            scheduleFitAudit()
            return
        }
        contentHost.layoutSubtreeIfNeeded()
        // A flexible settings viewport's fittingSize is a scroll-view layout hint,
        // not its requested window size. Its measured document/header supply that
        // destination independently, including the screen cap.
        let needed = panelState.showSettings && !panelState.showShortcuts
            ? desiredHeight : contentHost.fittingSize.height
        let actual = panel.frame.height
        // Logged before it is judged: a measurement rejected below is exactly the one
        // worth seeing when this audit turns out to be doing nothing.
        HeightTrace.log("audit window \(actual) vs fitting \(needed)")
        // A fitting size outside any height this panel could legitimately want means the
        // measurement itself is not to be trusted (an unconstrained proposal, a view mid
        // teardown). Repairing the window from it would be worse than the mismatch.
        guard needed >= Self.minimumPanelHeight, needed < 4_000 else { return }
        guard abs(actual - needed) > 1 else { return }

        HeightTrace.dump(reason: "window \(actual)pt, content needs \(needed)pt")

        // Shrink only after two settled measurements agree. A model change or a
        // new preference invalidates the candidate, so transient removal/layout
        // measurements cannot truncate newly arriving content.
        if needed < actual {
            guard let candidate = pendingShrinkHeight, abs(candidate - needed) <= 0.5 else {
                pendingShrinkHeight = needed
                scheduleFitAudit(confirmingShrink: true)
                return
            }
        }
        pendingShrinkHeight = nil
        var clamped = needed
        if let screenHeight = panel.screen?.visibleFrame.height {
            clamped = Self.clampedPanelHeight(desired: clamped, visibleHeight: screenHeight)
        }
        desiredHeight = ceil(clamped)
        guard Self.heightNeedsApply(actual: actual, target: desiredHeight) else { return }
        applyHeight(desiredHeight)
        scheduleFitAudit()
    }

    /// Moves the window to `target`, keeping the top edge anchored.
    ///
    /// The early-out compares against the window's *actual* height, never against
    /// `desiredHeight`. Those two can come apart — a resize animation interrupted by a
    /// panel drag (this window is `isMovableByWindowBackground`, and a pinned panel gets
    /// dragged around while it resizes), a frame set while the panel was ordered out, a
    /// screen clamp in `position()` — and comparing intent against intent means the one
    /// report that could repair the split is exactly the one that gets swallowed. The
    /// window then stays at the wrong height until the content height happens to change
    /// again, and because `NSHostingView` centres content that is shorter than its
    /// bounds, the error shows up split evenly across the top and bottom edges: the
    /// panel looks stretched, or looks like it is crushing its own padding.
    private func applyHeight(_ target: CGFloat) {
        HeightTrace.log("window \(panel.frame.height) -> \(target) (translating \(engine.isTranslating))")
        guard Self.heightNeedsApply(actual: panel.frame.height, target: target) else {
            // Even an already matching direct frame must cancel an older animation.
            if panelState.inputResizeInProgress { panel.setFrame(panel.frame, display: true) }
            return
        }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = top - target

        // How the window and the content stay together, and why this is not a second
        // timeline in disguise:
        //
        // SwiftUI does not hand out interpolated heights. A `GeometryReader` preference
        // fires *once* per transition, carrying the final value, about one layout pass
        // after the action starts — measured directly, not assumed. So this method never
        // sees the frames of the animation the view layer is running; it sees its
        // destination. The window therefore has to animate there itself, and the only way
        // for the two to look like one motion is for them to be the same animation:
        // `Theme.windowResizeDuration` is the duration of `.layout` (the one token
        // allowed to move the panel's height), and `caTimingFunction` is the same
        // curve `Theme.timed` builds from. Same start, same shape, same end.
        //
        // Two cases genuinely must not animate:
        //
        // - Streaming. Line growth arrives in a burst, and a fresh 0.22s animation per
        //   line would stack dozens of overlapping resizes and lag the text behind its
        //   own tokens. Nothing animates this in the view layer either, so setting the
        //   frame directly keeps both sides consistent.
        // - Reduce Motion. This panel resizes constantly; animating through that setting
        //   is a standing annoyance rather than a nicety.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if panelState.inputResizeInProgress || engine.isTranslating || reduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            // The panel owns one cancellable frame task. A direct input update
            // or another destination cancels it before writing the next frame.
            Self.animateResize(panel, to: frame)
        }
    }

    /// Shared with the native transition regression test so it exercises the same
    /// window animation used by the installed app.
    static func animateResize(_ window: NSWindow, to frame: NSRect) {
        if let panel = window as? FloatingPanel {
            panel.animateFrame(to: frame)
            return
        }
        // motion-exception: the window frame follows the shared native resize timeline.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.windowResizeDuration * Theme.animationScale
            context.timingFunction = Theme.caTimingFunction
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Repairs a window height the resize failed to reach. Recorded rather than logged:
    /// on its own this is a correction, not an incident, and the record is what the fit
    /// audit dumps if the panel does turn out to be the wrong size.
    private func verifyHeightLanded() {
        guard panel.isVisible else { return }
        let actual = panel.frame.height
        guard Self.heightNeedsApply(actual: actual, target: desiredHeight) else { return }
        HeightTrace.log("resize did not land: window \(actual) vs target \(desiredHeight); snapping")
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = desiredHeight
        frame.origin.y = top - desiredHeight
        panel.setFrame(frame, display: true)
    }

    // MARK: - Keyboard

    private var canHoldReturn: Bool {
        settings.holdReturnToRetranslate && panel.isKeyWindow && !panelState.showSettings && !panelState.showShortcuts
            && !panelState.showHistory && !panelState.showLanguagePicker
            && panelState.recordingShortcut == nil
            && (panel.firstResponder as? NSTextView)?.hasMarkedText() != true
            && settings.shortcut(.translate)?.isPlainReturn == true && engine.canRetranslate
    }

    private func cancelReturnHold() {
        returnHold.cancel()
        returnHoldTask?.cancel()
        returnHoldTask = nil
        panelState.returnHoldProgress = nil
    }

    private func beginReturnHold(_ event: NSEvent) {
        returnHold.begin(keyCode: event.keyCode, now: ProcessInfo.processInfo.systemUptime)
        panelState.returnHoldProgress = 0
        // Any intervening edit or result/configuration change invalidates this gesture.
        let input = engine.input
        let output = engine.output
        let target = engine.target
        let tone = settings.tone
        let extra = settings.extraInstruction
        returnHoldTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, let self else { return }
                guard self.canHoldReturn, self.engine.input == input, self.engine.output == output,
                      self.engine.target == target, self.settings.tone == tone,
                      self.settings.extraInstruction == extra else {
                    self.cancelReturnHold()
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                self.panelState.returnHoldProgress = self.returnHold.progress(now: now)
                if self.returnHold.fireIfReady(now: now) {
                    self.panelState.returnHoldProgress = nil
                    self.returnHoldTask = nil
                    self.engine.translate()
                    return
                }
            }
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyUp {
                guard self.returnHold.keyCode == event.keyCode else { return event }
                let submit = self.returnHold.release(keyCode: event.keyCode)
                self.cancelReturnHold()
                if submit && self.canHoldReturn { self.engine.submit() }
                return nil
            }
            if event.type != .keyDown {
                self.cancelReturnHold()
                return event
            }
            // A swallowed key-up while another application was active must not leave
            // the next physical press stuck. Auto-repeat is never a fresh gesture.
            if !event.isARepeat, self.returnHold.keyCode == event.keyCode {
                self.cancelReturnHold()
                self.returnHold = ReturnHold()
            }
            if self.returnHold.keyCode == event.keyCode { return nil }
            if self.returnHold.keyCode != nil { self.cancelReturnHold() }

            let flags = KeyCombo.normalized(event.modifierFlags)

            // Recording a new shortcut swallows everything until it gets a valid combo —
            // in whichever Tusi window is recording, which is normally Settings.
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

            guard self.panel.isKeyWindow else { return event }

            // While an input method is composing marked text, Return commits the
            // candidate and Esc cancels it. Those events must reach NSTextView before
            // panel shortcuts get a chance to consume them.
            if (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true {
                return event
            }

            // Close / back — configurable (default Esc). Backs out one level at a time:
            // Shortcuts → Settings → Translator → hide. Backing out of a page matches
            // the on-screen back buttons; hiding the panel stays silent so the frequent
            // Esc-to-dismiss doesn't get noisy.
            if let combo = self.settings.shortcut(.close), combo.matches(event) {
                if self.panelState.showShortcuts {
                    self.panelState.showShortcuts = false
                } else if self.panelState.showSettings {
                    self.panelState.showSettings = false
                } else {
                    self.hide()
                }
                return nil
            }

            // ⌘, opens settings (not user-configurable — a macOS convention).
            if flags == .command, event.charactersIgnoringModifiers == "," {
                self.panelState.showSettings = true
                return nil
            }

            // Let text fields in settings behave normally.
            guard !self.panelState.showSettings else { return event }

            if let combo = self.settings.shortcut(.history), combo.matches(event) {
                self.panelState.showHistory.toggle()
                return nil
            }

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
                guard !event.isARepeat else { return nil }
                if combo.isPlainReturn && self.canHoldReturn {
                    self.beginReturnHold(event)
                    return nil
                }
                // `submit`, not `translate`: once a result is on screen and a better
                // tier is available, this key asks for that instead of re-running the
                // same model. See `TranslationEngine.submit`.
                self.engine.submit()
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

        if let clash = settings.shortcutConflict(combo, for: action) {
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
                guard let self else { return }
                self.cancelReturnHold()
                guard !self.panelState.pinned else { return }
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

    func windowDidChangeScreen(_ notification: Notification) {
        if let screen = panel.screen {
            panelState.availableHeight = screen.visibleFrame.height - 12
            setContentHeight(desiredHeight)
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: min(max(frameSize.width, Theme.panelMinWidth), Theme.panelMaxWidth),
            height: desiredHeight
        )
    }

    func windowDidResize(_ notification: Notification) {
        let width = min(max(panel.frame.width, Theme.panelMinWidth), Theme.panelMaxWidth)
        guard abs(width - panelState.panelWidth) > 0.5 else { return }
        // Live-updates the UI binding every tick of the drag, but does NOT persist —
        // `settings.panelWidth`'s didSet writes UserDefaults synchronously, and a drag
        // fires this dozens of times. Persisting happens once, in
        // `windowDidEndLiveResize`, when the user actually settles on a width.
        panelState.panelWidth = width
    }

    /// Moving the panel by hand pins it: a panel dragged out of its place under the menu
    /// bar has been put somewhere on purpose, the way a detachable popover becomes its own
    /// window. Only a real drag counts — every programmatic frame change (positioning,
    /// resize animation) happens with no mouse button held.
    func windowWillMove(_ notification: Notification) {
        guard NSEvent.pressedMouseButtons & 1 == 1, panel.isVisible else { return }
        panelState.pinned = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        settings.panelWidth = panelState.panelWidth
    }
}
