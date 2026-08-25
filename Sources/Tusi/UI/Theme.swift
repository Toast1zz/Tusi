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
    /// Fields, buttons, cards.
    static let radiusStandard: CGFloat = 8
    /// Larger cards, error box, history rows.
    static let radiusLarge: CGFloat = 9
    /// The update/toast surface.
    static let radiusToast: CGFloat = 10

    // MARK: - Animation

    /// Fast feedback: hover states, icon micro-interactions.
    static let durationFast: Double = 0.15
    /// Standard transitions: toggles, tabs, small layout changes.
    static let durationStandard: Double = 0.2
    /// Larger transitions: view changes, panel chrome.
    static let durationSlow: Double = 0.25
    /// Tone selector's sliding pill — slightly longer for the matched-geometry motion.
    static let durationTone: Double = 0.3

    /// TUSI_SLOWMO stretches every panel animation so transitions can be inspected
    /// frame by frame. 1 in normal runs.
    static let animationScale: Double = ProcessInfo.processInfo.environment["TUSI_SLOWMO"] != nil ? 10 : 1

    /// Standard snappy animation curve with a given duration. Honors System Settings ▸
    /// Accessibility ▸ Display ▸ Reduce Motion: this app animates a lot (page pushes,
    /// pill sliding, panel resizing, toasts), and ignoring that setting would make every
    /// one of them a standing annoyance for users who turned it on.
    static func snappy(_ duration: Double) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .linear(duration: 0)
        }
        return .snappy(duration: duration * animationScale)
    }
}
