import AppKit
import SwiftUI

/// Central design tokens for Tusi. Every visual constant that repeats across the UI
/// lives here so the interface reads as one coherent system instead of a collection
/// of per-view literals.
///
/// Type scale (from the audit of all `.system(size:)` call sites):
/// - 9    → `.caption2` — badge counts, tiny metadata
/// - 10   → `.caption`   — secondary labels, hints, field captions
/// - 11   → `.footnote`  — compact controls, chip labels, history meta
/// - 12   → `.bodySmall` — button text, compact labels
/// - 12.5 → `.body`      — settings rows, field content
/// - 14   → `.title`     — page headers
/// - 15   → `.content`   — main input/result text
/// - 18   → `.emptyState` — empty-state hero icons
enum Theme {
    /// System accent color — whatever the user picked in System Settings ▸ Appearance.
    /// Using it (instead of a baked-in brand gradient) is what makes controls read as
    /// native macOS chrome rather than a cross-platform app that shipped its own palette.
    static let accent = Color.accentColor
    static let success = Color(nsColor: .systemGreen)

    // MARK: - Fill tokens
    //
    // Audited every `Color.primary.opacity(…)` call site in the UI: 0.05 / 0.055 / 0.06
    // showed up five separate times as "a static quiet background", 0.065 / 0.07 four
    // times as "a hover background", 0.07 / 0.08 as "a hairline stroke" — different
    // numbers picked at different times for the same intent, not deliberately distinct
    // steps. Collapsed to the tokens below; each one now means exactly one thing.
    //
    // Left alone (not part of this system): SoftDivider's gradient stops (a fade
    // curve, not a flat fill), the 0.35/0.18 shadow and placeholder-dot opacities, and
    // anything ≥0.6 (those are foreground/text opacities, a different axis entirely).

    /// The faintest tier: a resting state that must stay barely-there so a hover state
    /// two tiers up still reads as a real change (history rows).
    static let fillFaint = Color.primary.opacity(0.025)
    /// Static quiet backgrounds: field chrome, badges, unselected pills/tabs/rows.
    static let fillQuiet = Color.primary.opacity(0.05)
    /// Hover state, and anywhere a slightly stronger presence than `fillQuiet` is
    /// deliberate (not another accidental near-duplicate of it).
    static let fillHover = Color.primary.opacity(0.07)
    /// Stronger emphasis fill: the skeleton-loading bars, and a chip's engaged state
    /// (flipped/expanded) — anything that wants to read as more "present" than a quiet
    /// background without being a hover state.
    static let fillActive = Color.primary.opacity(0.1)
    /// Borders and field outlines.
    static let strokeHairline = Color.primary.opacity(0.08)
    /// ToneSelector's selection pill on macOS < 26 (the Liquid Glass fallback) — its
    /// own tier because a selection indicator is deliberately more present than any
    /// hover state, and it's the only thing in the UI that needs to be.
    static let fillSelection = Color.primary.opacity(0.14)

    /// The panel's physical surface corner. Larger than any inner control radius so
    /// nested corners stay visually distinct.
    static let panelCornerRadius: CGFloat = 20

    /// Panel width bounds, shared by `PanelController`'s init/resize handling and the
    /// persisted-width clamp in `SettingsStore` — one source instead of the same two
    /// literals typed out at four call sites.
    static let panelMinWidth: CGFloat = 470
    static let panelMaxWidth: CGFloat = 700

    /// The shared content font for the translator input and result text.
    static let contentFont = Font.system(size: 15)

    // MARK: - Typography

    // Base sizes (regular weight unless noted).

    /// 9pt — the smallest metadata: badge counts, tiny inline labels.
    static let caption2 = Font.system(size: 9)
    /// 10pt — secondary labels, hints, field captions.
    static let caption = Font.system(size: 10)
    /// 11pt — compact controls, chip labels, history metadata, toasts.
    static let footnote = Font.system(size: 11)
    /// 12pt — button text, compact labels, small icons.
    static let bodySmall = Font.system(size: 12)
    /// 12.5pt — settings rows, field content, larger labels.
    static let body = Font.system(size: 12.5)
    /// 14pt — page headers (Settings, Shortcuts).
    static let title = Font.system(size: 14, weight: .semibold)
    /// 15pt — the main input/result text (alias of `contentFont`).
    static let content = Font.system(size: 15)
    /// 18pt — empty-state hero icon.
    static let emptyState = Font.system(size: 18, weight: .light)

    // Weighted/specialized variants used by controls.

    /// 9pt semibold — badge counts.
    static let caption2Semibold = Font.system(size: 9, weight: .semibold)
    /// 9.5pt semibold rounded — history count badge.
    static let caption2Rounded = Font.system(size: 9.5, weight: .semibold, design: .rounded)
    /// 10pt medium — small button labels.
    static let captionMedium = Font.system(size: 10, weight: .medium)
    /// 10pt semibold — emphasized small labels.
    static let captionSemibold = Font.system(size: 10, weight: .semibold)
    /// 10.5pt medium — secondary action labels.
    static let caption2Medium = Font.system(size: 10.5, weight: .medium)
    /// 10.5pt bold — copy button icon.
    static let caption2Bold = Font.system(size: 10.5, weight: .bold)
    /// 11pt medium — compact control labels.
    static let footnoteMedium = Font.system(size: 11, weight: .medium)
    /// 11pt semibold — section headers in the translator.
    static let footnoteSemibold = Font.system(size: 11, weight: .semibold)
    /// 11pt semibold rounded — direction chip.
    static let footnoteRounded = Font.system(size: 11, weight: .semibold, design: .rounded)
    /// 11.5pt medium — update status, recording state.
    static let footnote2Medium = Font.system(size: 11.5, weight: .medium)
    /// 11.5pt semibold — slot tab label.
    static let footnote2Semibold = Font.system(size: 11.5, weight: .semibold)
    /// 12pt medium — icon button glyphs.
    static let bodySmallMedium = Font.system(size: 12, weight: .medium)
    /// 12pt semibold — primary button text.
    static let bodySmallSemibold = Font.system(size: 12, weight: .semibold)
    /// 12.5pt monospaced — code-like fields (base URL, model, key, routing).
    static let bodyMonospaced = Font.system(size: 12.5, design: .monospaced)
    /// 10.5pt semibold/medium toggle — tone selector labels.
    static let toneLabel = Font.system(size: 10.5, weight: .semibold)
    /// 8pt bold — direction arrow.
    static let arrowBold = Font.system(size: 8, weight: .bold)
    /// 11.5pt medium, rounded — the shortcut combo pill in its resting state.
    static let shortcutCombo = Font.system(size: 11.5, weight: .medium, design: .rounded)
    /// 11.5pt medium, default — the same pill while a shortcut is being recorded
    /// (recording swaps away from the rounded design so the active state reads as
    /// a fresh field, not a settled badge).
    static let shortcutComboRecording = Font.system(size: 11.5, weight: .medium)

    // MARK: - Corner radii

    /// Small inline elements: badges, tiny pills.
    static let radiusSmall: CGFloat = 6
    /// Everything else: fields, buttons, cards, history rows, the toast surface.
    /// Used to be three separate values (8/9/10) a single point apart — a difference
    /// no eye can actually pick out, so it was cycle-of-history, not a real scale.
    static let radiusStandard: CGFloat = 8

    // MARK: - Animation
    //
    // A tool panel's chrome (folds, page pushes, toggles, panel resizing) is a state
    // switch, not a direct-manipulation gesture — it should decelerate cleanly and
    // never overshoot. SwiftUI's `.snappy` is a spring with built-in bounce, which is
    // the wrong shape for that: it reads as "bouncy" precisely where the system
    // conventions (Spotlight, menus, popovers) read as "crisp". Every animation in this
    // app goes through `motion(_:)` below except `selectionSlide`, the one place a
    // spring is actually correct (a pill sliding to a new position has real inertia).
    //
    // `motion(_:)` and `caTimingFunction` are built from the SAME control points on
    // purpose: PanelController's AppKit-side window resize and this file's SwiftUI
    // curves need to move in lockstep during a fold/unfold, or the window and its
    // content visibly drift apart mid-animation.

    /// The one curve every non-spring animation in the app uses: fast start, clean
    /// deceleration, zero overshoot.
    private static let curve: (Double, Double, Double, Double) = (0.2, 0.8, 0.3, 1.0)

    /// AppKit equivalent of `curve`, for `NSAnimationContext` (PanelController's window
    /// resize) — same shape as every SwiftUI animation below, so the window and its
    /// content stay in sync during a layout change instead of drifting apart on two
    /// different timing curves.
    static var caTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1), Float(curve.2), Float(curve.3))
    }

    /// TUSI_SLOWMO stretches every panel animation so transitions can be inspected
    /// frame by frame. 1 in normal runs.
    static let animationScale: Double = ProcessInfo.processInfo.environment["TUSI_SLOWMO"] != nil ? 10 : 1

    /// Every non-spring animation's sole entry point. Honors System Settings ▸
    /// Accessibility ▸ Display ▸ Reduce Motion — this app animates a lot (page pushes,
    /// folds, panel resizing, toasts), and ignoring that setting would make every one of
    /// them a standing annoyance for users who turned it on. Checked in exactly one
    /// place so it can never be forgotten at a call site.
    private static func motion(_ duration: Double) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .linear(duration: 0)
        }
        return .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration * animationScale)
    }

    /// Hover states, icon micro-interactions — the fastest, most frequent feedback.
    static var microMotion: Animation { motion(0.12) }
    /// Toggles, selection changes, chevrons, toasts — a discrete state flipping.
    static var stateChange: Animation { motion(0.18) }
    /// Content folding/unfolding, rows appearing or disappearing, panel height
    /// following content. Also the duration `PanelController` mirrors on the AppKit
    /// side via `layoutChangeDuration` + `caTimingFunction`.
    static var layoutChange: Animation { motion(0.22) }
    /// Pushing between the translator, settings, and shortcuts pages.
    static var pageTransition: Animation { motion(0.28) }

    /// Seconds version of `layoutChange`'s duration, for `NSAnimationContext.duration`
    /// (which takes a `TimeInterval`, not an `Animation`). Keep in sync with the 0.22
    /// above by construction if you ever change one — they're meant to match exactly.
    static let layoutChangeDuration: Double = 0.22

    /// The one legitimate spring in the app: ToneSelector's sliding selection pill has
    /// real inertia (a shape moving from one resting position to another), unlike
    /// everything else here, which is a state switching, not an object moving.
    static var selectionSlide: Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .linear(duration: 0)
        }
        return .spring(duration: 0.3 * animationScale, bounce: 0.15)
    }
}
