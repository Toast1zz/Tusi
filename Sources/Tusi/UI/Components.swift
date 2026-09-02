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
        .onHover { inside in
            withAnimation(Theme.microMotion) { hovering = inside }
        }
        .help(L("选择目标语言"))
        .animation(Theme.stateChange, value: isActive)
        .animation(Theme.stateChange, value: sourceLabel)
        .animation(Theme.stateChange, value: isFlipped)
        .animation(Theme.stateChange, value: isExpanded)
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
        .onHover { inside in
            withAnimation(Theme.microMotion) { hovering = inside }
        }
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
                    withAnimation(Theme.selectionSlide) { tone = option }
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
    var shortcutHint: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Theme.caption2Bold)
                Text(copied ? "已复制" : "复制")
                    .font(Theme.bodySmallSemibold)
                    .lineLimit(1)
                if !copied, let shortcutHint, !shortcutHint.isEmpty {
                    Text(shortcutHint)
                        .font(Theme.captionMedium)
                        .opacity(0.65)
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(copied ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.accent))
            )
            .brightness(hovering && !copied ? 0.06 : 0)
            .scaleEffect(hovering && !copied ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(copied ? "已复制" : "复制")
        .animation(Theme.stateChange, value: copied)
        .animation(Theme.microMotion, value: hovering)
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

    /// The one deliberate exception to "everything routes through Theme.motion":
    /// a decorative loop, not a state transition, so easeInOut + repeatForever is the
    /// right shape here rather than a bug. Still honors Reduce Motion — a system
    /// setting meant to stop exactly this kind of continuous animation — by never
    /// starting the pulse and resting at a fixed, still-legible opacity instead.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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

/// Bottom transient toast — copy confirmation or a one-time "switched to backup" notice.
struct Toast: View {
    let icon: String
    let text: String
    var tint: AnyShapeStyle

    static func fellBack() -> Toast {
        Toast(icon: "arrow.triangle.branch", text: L("主用连接失败，已用备用翻译"), tint: AnyShapeStyle(Color.orange))
    }

    static func truncatedInput() -> Toast {
        Toast(
            icon: "scissors",
            text: String(format: L("已截断至 %d 字"), TranslationEngine.maxInputCharacters),
            tint: AnyShapeStyle(Color.secondary)
        )
    }

    static func copyFailed() -> Toast {
        Toast(icon: "exclamationmark.triangle.fill", text: L("复制失败，请重试"), tint: AnyShapeStyle(Color.orange))
    }

    /// One-time, informational (not a warning — `.secondary`, not `.orange` like
    /// `fellBack`) notice for `SettingsStore.raceFastestEnabled`. `label` is already
    /// the short per-slot name (e.g. "deepseek", from `SettingsStore.label(for:)`),
    /// not the full host — kept to a glance, not a sentence, since it fires on every
    /// successful race rather than a rare event.
    static func raceWon(_ label: String) -> Toast {
        Toast(
            icon: "bolt.fill",
            text: label.isEmpty ? L("更快") : String(format: L("%@ 更快"), label),
            tint: AnyShapeStyle(Color.secondary)
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(Theme.bodySmallSemibold)
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.bodySmallMedium)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(Capsule().strokeBorder(Theme.strokeHairline, lineWidth: 1))
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
