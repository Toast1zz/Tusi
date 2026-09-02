import SwiftUI
import AppKit

// MARK: - Window background material

/// The panel's physical surface: frosted material, rounded corners, hairline border and a
/// faint top-light. It is an AppKit view rather than a SwiftUI background because it has to
/// track the *window's* bounds exactly. Sized from SwiftUI content instead, it drifts out
/// of alignment whenever the content and the window animate on different timelines, and
/// the corners flash square in the gap.
final class PanelContainerView: NSView {
    private let effect = NSVisualEffectView()
    private let topLight = CAGradientLayer()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        topLight.startPoint = CGPoint(x: 0.5, y: 0)
        topLight.endPoint = CGPoint(x: 0.5, y: 0.5)
        effect.layer?.addSublayer(topLight)

        applyAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func layout() {
        super.layout()
        // The gradient is a raw layer, so it has no autoresizing of its own. Resizing it
        // without disabling implicit animation would let it lag a resize by a frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topLight.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        // labelColor is dynamic; resolving it to a CGColor needs the right appearance
        // to be current, otherwise the border keeps whatever it resolved to first.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            self.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            self.topLight.colors = [
                NSColor.white.withAlphaComponent(isDark ? 0.06 : 0.5).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ]
        }
    }
}

// MARK: - Small controls

/// Quiet icon button used in the bottom bar (pin, settings, stop).
struct BarIconButton: View {
    let systemName: String
    var isActive = false
    var help: String
    /// Optional vertical nudge for the glyph inside its 26×26 frame. SF Symbols have
    /// different optical baselines — e.g. `pin` is a 14pt-tall glyph next to 13pt
    /// circles (clock/gearshape) at the same font size, so it visually sits higher.
    /// A small downward offset aligns it with its neighbors. Clickable area unchanged.
    var glyphOffset: CGFloat = 0
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.bodySmallMedium)
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .offset(y: glyphOffset)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(hovering ? Theme.fillHover : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(LocalizedStringKey(help))
        // `help` arrives as a plain, untranslated String from every call site — wrapping
        // it in LocalizedStringKey here (once) sends it through the same table lookup a
        // literal `.help("...")` would get, without repeating that at each call site.
        .help(LocalizedStringKey(help))
    }
}

/// Direction indicator. Before anything is typed there is no direction to show — the app
/// hasn't detected a language yet — so it reads "自动", and only resolves to "中 → EN"
/// (or the reverse) once there's input to judge.
///
/// Direction chip: shows the current translation direction (`中 → EN`) and opens the
/// inline target-language picker when tapped. The picker is the single control for
/// both "auto CN↔EN" and "explicit target" — there is no separate mode switch. The
/// chevron rotates with the picker so the chip reads as expandable, not as a label.
struct DirectionChip: View {
    let sourceLabel: String
    let target: TranslationLanguage
    let isActive: Bool
    /// Manual direction override engaged (flipped via the picker row in auto mode).
    let isFlipped: Bool
    /// Whether the inline picker this chip controls is currently expanded.
    let isExpanded: Bool
    var onTap: (() -> Void)? = nil

    @State private var hovering = false

    private var targetLabel: String { target.symbol }

    var body: some View {
        // A real Button (not onTapGesture + .isButton trait) so Tab and VoiceOver can
        // actually activate it, not just announce it as one.
        Button {
            onTap?()
        } label: {
            HStack(spacing: 5) {
                if isActive {
                    Text(sourceLabel)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(Theme.arrowBold)
                    Text(targetLabel)
                        .lineLimit(1)
                } else {
                    Image(systemName: "sparkles")
                        .font(Theme.caption2Semibold)
                    Text("自动")
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(Theme.caption2Semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(Theme.footnoteRounded)
            .fixedSize(horizontal: true, vertical: false)
            // .secondary, not .tertiary: "自动" and the tone selector's unselected labels are
            // both "inactive, not currently the point" — they should sit at the same weight.
            // The capsule background used to paper over the mismatch; plain text doesn't.
            .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background {
                if hovering || isFlipped || isExpanded {
                    Capsule().fill(isFlipped || isExpanded ? Theme.fillActive : Theme.fillQuiet)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("选择目标语言"))
        .motion(.micro, value: hovering)
        .motion(.state, value: restingState)
    }

    /// All four of the chip's resting-state inputs change for the same reason (the user
    /// typed, flipped, or opened the picker) and animate identically, so they ride one
    /// modifier instead of four stacked ones that would each claim to be a separate
    /// cause.
    private struct RestingState: Equatable {
        let isActive: Bool
        let sourceLabel: String
        let isFlipped: Bool
        let isExpanded: Bool
    }

    private var restingState: RestingState {
        RestingState(isActive: isActive, sourceLabel: sourceLabel, isFlipped: isFlipped, isExpanded: isExpanded)
    }
}

/// One capsule in the inline target-language picker row. Mirrors the capsule style the
/// old Settings grid used (accent fill when selected, quiet fill otherwise) so the
/// control reads as kin to ToneSelector rather than a new visual species.
struct LanguagePill: View {
    let label: String
    let selected: Bool
    var icon: String? = nil
    let action: () -> Void

    // Every other control in this row (ToneSelector, DirectionChip) has a hover
    // state; this pill was the one dead spot — same fillQuiet→fillHover swap
    // unselected pills use elsewhere, and the same brightness bump CopyButton uses
    // for its own solid-accent hover state when selected.
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(Theme.caption2Semibold)
                }
                Text(label)
                    .font(Theme.footnote)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(
                Capsule().fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(hovering ? Theme.fillHover : Theme.fillQuiet))
            )
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .brightness(hovering && selected ? 0.06 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.micro, value: hovering)
        .motion(.state, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Inline three-way tone picker. Deliberately a segmented control rather than a menu:
/// a popup would make the panel resign key and trip the click-outside auto-hide.
///
/// The selection indicator is a single pill that *slides* between options via
/// matchedGeometryEffect, rather than fading in and out under each one. On macOS 26+ it's
/// Liquid Glass in Clear mode — this control doesn't need to grab attention, so a quiet
/// refractive pill suits it better than a solid accent fill; older systems get a soft
/// translucent capsule instead.
struct ToneSelector: View {
    @Binding var tone: Tone
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tone.allCases) { option in
                let selected = option == tone
                Button {
                    tone = option
                } label: {
                    Text(option.label)
                        .font(selected ? Theme.toneLabel : Theme.caption2Medium)
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        // Without this, these labels could get silently truncated (seen
                        // with the longer English tone names) instead of reporting their
                        // real width — .fixedSize() forces Text to always claim what it
                        // actually needs.
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background {
                            if selected {
                                SelectionPill().matchedGeometryEffect(id: "tonePill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fillQuiet))
        // Declared here rather than wrapped around the mutation in the button: the pill
        // has to slide whoever changed the tone, including the settings page and the
        // keyboard, and a `withAnimation` at one call site only covers that call site.
        .motion(.selection, value: tone)
    }

    /// The sliding highlight. Clear Liquid Glass where the OS supports it, a soft
    /// translucent capsule everywhere else.
    private struct SelectionPill: View {
        var body: some View {
            if #available(macOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.clear, in: Capsule())
            } else {
                Capsule().fill(Theme.fillSelection)
            }
        }
    }
}

/// Primary copy button — flat solid capsule that morphs into a green check.
struct CopyButton: View {
    let copied: Bool
    /// The pasteboard write was rejected. Reported here, by the control that was asked
    /// to do it, rather than by a banner floating over the text it failed to copy.
    var failed = false
    var shortcutHint: String?
    let action: () -> Void

    @State private var hovering = false

    private enum Phase: CaseIterable {
        case idle, copied, failed
    }

    private var phase: Phase {
        if failed { return .failed }
        return copied ? .copied : .idle
    }

    private var fill: AnyShapeStyle {
        switch phase {
        case .failed: return AnyShapeStyle(Color.orange)
        case .copied: return AnyShapeStyle(Theme.success)
        case .idle: return AnyShapeStyle(Theme.accent)
        }
    }

    private var accessibilityTitle: LocalizedStringKey {
        switch phase {
        case .failed: return "复制失败"
        case .copied: return "已复制"
        case .idle: return "复制"
        }
    }

    var body: some View {
        Button(action: action) {
            // Every phase is laid out, only one is drawn: the capsule is therefore as
            // wide as its widest wording and never changes size. It used to swap
            // "复制 ⇧⌘C" for "已复制", which is a different string and a different
            // number of children — so confirming a copy resized the control, and the
            // bottom bar shifted under the cursor that had just clicked it. A control
            // confirming itself should look like the same control.
            ZStack {
                ForEach(Phase.allCases, id: \.self) { candidate in
                    label(for: candidate)
                        .opacity(candidate == phase ? 1 : 0)
                        .accessibilityHidden(candidate != phase)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(fill))
            // Brightness only. This used to also scale to 1.03 on hover, which made it
            // the one control in the app that grows under the cursor — every other
            // hover state in the panel is a fill or brightness change, and the odd one
            // out reads as a glitch rather than as emphasis.
            .brightness(hovering && phase == .idle ? 0.06 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilityTitle)
        .motion(.state, value: phase)
        .motion(.micro, value: hovering)
    }

    @ViewBuilder
    private func label(for phase: Phase) -> some View {
        HStack(spacing: 5) {
            Image(systemName: {
                switch phase {
                case .failed: return "exclamationmark.triangle.fill"
                case .copied: return "checkmark"
                case .idle: return "doc.on.doc"
                }
            }())
                .font(Theme.caption2Bold)
                // A symbol swapping for another symbol, animated as exactly that. The
                // alternative (fade one out, fade the other in) reads as two separate
                // glyphs rather than one control confirming itself.
                .contentTransition(.symbolEffect(.replace))
            Text({
                switch phase {
                case .failed: return LocalizedStringKey("复制失败")
                case .copied: return LocalizedStringKey("已复制")
                case .idle: return LocalizedStringKey("复制")
                }
            }())
                .font(Theme.bodySmallSemibold)
                .lineLimit(1)
            if phase == .idle, let shortcutHint, !shortcutHint.isEmpty {
                Text(shortcutHint)
                    .font(Theme.captionMedium)
                    .opacity(0.65)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A `Disclosure`'s measured natural height. File-scope because a `PreferenceKey` cannot
/// be nested inside a generic type; nothing else should use it.
struct DisclosureHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The app's one way to fold content away, and the reason the window no longer needs a
/// second timeline.
///
/// `if expanded { … }` inside a stack changes that stack's height in a single step, so
/// the panel could only ever cut to the new size — which is why the settings folds used
/// to animate nothing but their chevron and let the field pop in at full opacity. Here
/// the content is always laid out at its natural size and the *container's* height is
/// what animates, so the height passes through every value in between, SwiftUI stays the
/// only timeline, and the window has something continuous to mirror.
///
/// `.fixedSize(vertical:)` is load-bearing: it makes the content report its ideal height
/// even while the frame around it is proposing zero. Without it the measurement collapses
/// along with the fold and the section can never open again.
struct Disclosure<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder var content: Content

    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DisclosureHeightKey.self, value: proxy.size.height)
                }
            )
            .frame(height: isExpanded ? naturalHeight : 0, alignment: .top)
            .opacity(isExpanded ? 1 : 0)
            .clipped()
            // Collapsed content is still in the view tree (that is how it stays
            // measured), so it has to be taken out of the tab order and off the
            // accessibility tree explicitly — otherwise Tab lands in an invisible text
            // field and VoiceOver reads a section the user closed.
            .disabled(!isExpanded)
            .accessibilityHidden(!isExpanded)
            .onPreferenceChange(DisclosureHeightKey.self) { naturalHeight = $0 }
    }
}

/// Soft hairline divider that fades out at both ends.
struct SoftDivider: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.primary.opacity(0.0),
                Color.primary.opacity(0.12),
                Color.primary.opacity(0.12),
                Color.primary.opacity(0.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }
}

/// Skeleton shown while waiting for the first streamed token.
struct StreamingPlaceholder: View {
    @State private var pulsing = false

    /// The one deliberate exception to "everything goes through `.motion`": a decorative
    /// loop, not a state transition, so easeInOut + repeatForever is the right shape here
    /// rather than a bug. Still honors Reduce Motion — a system setting aimed at exactly
    /// this kind of continuous animation — by never starting the pulse and resting at a
    /// fixed, still-legible opacity instead.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar(widthFraction: 0.92)
            bar(widthFraction: 0.74)
            bar(widthFraction: 0.5)
        }
        .opacity(reduceMotion ? 0.6 : (pulsing ? 0.35 : 0.9))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)  // motion-exception: decorative loop, see doc comment above
        .onAppear {
            guard !reduceMotion else { return }
            pulsing = true
        }
        // Turning the setting on mid-pulse has to stop it, not wait for the next
        // translation — which is the whole reason Reduce Motion is read from the
        // environment now instead of straight off NSWorkspace.
        .onChange(of: reduceMotion) { _, isOn in
            pulsing = !isOn
        }
    }

    private func bar(widthFraction: CGFloat) -> some View {
        GeometryReader { proxy in
            // 4pt, deliberately smaller than the 6pt control radius: skeleton bars are
            // fine decorative lines, not interactive controls — a tighter corner keeps
            // them from reading as buttons.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.fillActive)
                .frame(width: proxy.size.width * widthFraction)
        }
        .frame(height: 11)
    }
}

/// Where the result on screen came from. A statement, not a control.
///
/// This used to be a two-segment pill that both named the source and switched between
/// versions — which put it in the same clothes as the tone selector one row below, and
/// welded two different parts of speech together. Attribution is a label; showing the
/// other version is an action, and the action lives on the other end of the row where
/// every other result-row action already lives.
struct ResultProvenance: View {
    let label: String
    let isLocal: Bool
    /// This answer exists only because the slot ahead of it failed — the one thing the
    /// old "已用备用翻译" toast said that the slot name alone does not.
    let afterFailover: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: afterFailover
                  ? "arrow.triangle.branch"
                  : (isLocal ? "desktopcomputer" : "cloud"))
                .font(Theme.caption2)
            Text(afterFailover ? String(format: L("%@ · 主用失败后接手"), label) : label)
                .font(Theme.caption)
                .lineLimit(1)
        }
        .foregroundStyle(afterFailover ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("结果来自 %@"), label))
    }
}

// MARK: - Error box

struct ErrorBox: View {
    let message: String
    /// The action that actually addresses this failure. "Retry" is right for a dropped
    /// connection and useless for an unconfigured endpoint — offering it there just
    /// reproduces the same error in front of the user, so the caller decides.
    let primaryLabel: String
    let primaryAction: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.footnote)
                .foregroundStyle(.orange)
            Text(message)
                .font(Theme.bodySmall)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(primaryLabel, action: primaryAction)
                .buttonStyle(.plain)
                .font(Theme.bodySmallSemibold)
                .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusStandard, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }
}

/// A row-wide segmented choice: a title, the options, and one caption that describes
/// what the *selected* option actually does.
///
/// Deliberately not a switch. A switch answers "on or off", and every routing question
/// in this app is "which of these", which a switch can only express by pairing with
/// another switch — the arrangement that let racing be silently disabled by the
/// fallback toggle. The caption belongs to the selection, not to the control, so the
/// page always states the behavior the user is about to get rather than the one the
/// label happens to name.
struct SegmentedChoice: View {
    struct Option: Identifiable, Equatable {
        var id: String
        var label: String
        /// When set, the option is shown but unselectable, and this says why. Hiding it
        /// instead would leave the user looking for a feature they read about with no
        /// hint that two fields above are what stand in the way.
        var disabledReason: String?
    }

    let title: String
    let options: [Option]
    let selection: String
    let onSelect: (String) -> Void
    var caption: String?

    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.body)
                    .fixedSize()
                Spacer(minLength: 8)
                segments
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.id == selection
                let disabled = option.disabledReason != nil
                Button {
                    onSelect(option.id)
                } label: {
                    Text(option.label)
                        .font(selected ? Theme.caption2Semibold : Theme.caption2Medium)
                        .foregroundStyle(
                            disabled ? AnyShapeStyle(.quaternary)
                                : selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                        )
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                ChoicePill().matchedGeometryEffect(id: "choicePill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help(option.disabledReason ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fillQuiet))
        .motion(.selection, value: selection)
    }

    private struct ChoicePill: View {
        var body: some View {
            if #available(macOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.clear, in: Capsule())
            } else {
                Capsule().fill(Theme.fillSelection)
            }
        }
    }
}
