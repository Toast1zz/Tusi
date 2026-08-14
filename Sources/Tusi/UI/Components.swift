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
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
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
/// In simple CN↔EN mode the chip doubles as a manual override for the rare case the
/// auto-detected direction is wrong: hovering gives it the same capsule affordance the
/// other clickable controls wear, and tapping flips the direction for the current input.
/// The flip is scoped to the input — any edit returns to auto-detection. In multi-language
/// mode there is no "opposite side" to flip to, so the chip is a plain label again.
struct DirectionChip: View {
    let sourceLabel: String
    let target: TranslationLanguage
    let isActive: Bool
    /// Manual direction override engaged (chip tapped in simple mode).
    let isFlipped: Bool
    /// Whether tapping is offered at all. Simple CN↔EN mode only.
    var isInteractive: Bool = false
    var onFlip: (() -> Void)? = nil

    @State private var hovering = false

    private var targetLabel: String { target.symbol }

    var body: some View {
        HStack(spacing: 5) {
            if isActive {
                Text(sourceLabel)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                Text(targetLabel)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                Text("自动")
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        // .secondary, not .tertiary: "自动" and the tone selector's unselected labels are
        // both "inactive, not currently the point" — they should sit at the same weight.
        // The capsule background used to paper over the mismatch; plain text doesn't.
        .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background {
            if hovering || isFlipped {
                Capsule().fill(Color.primary.opacity(isFlipped ? 0.08 : 0.05))
            }
        }
        .contentShape(Capsule())
        .onHover { inside in
            withAnimation(.snappy(duration: 0.15)) { hovering = inside }
        }
        .onTapGesture {
            guard isInteractive else { return }
            onFlip?()
        }
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .help(isInteractive ? L("切换翻译方向") : "")
        .animation(.snappy(duration: 0.2), value: isActive)
        .animation(.snappy(duration: 0.2), value: sourceLabel)
        .animation(.snappy(duration: 0.2), value: isFlipped)
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
                    withAnimation(.snappy(duration: 0.3 * Theme.animationScale)) { tone = option }
                } label: {
                    Text(option.label)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
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
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    /// The sliding highlight. Clear Liquid Glass where the OS supports it, a soft
    /// translucent capsule everywhere else.
    private struct SelectionPill: View {
        var body: some View {
            if #available(macOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.clear, in: Capsule())
            } else {
                Capsule().fill(Color.primary.opacity(0.14))
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
                    .font(.system(size: 10.5, weight: .bold))
                Text(copied ? "已复制" : "复制")
                    .font(.system(size: 12, weight: .semibold))
                if !copied, let shortcutHint, !shortcutHint.isEmpty {
                    Text(shortcutHint)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.65)
                }
            }
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
        .animation(.snappy(duration: 0.22), value: copied)
        .animation(.snappy(duration: 0.15), value: hovering)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar(widthFraction: 0.92)
            bar(widthFraction: 0.74)
            bar(widthFraction: 0.5)
        }
        .opacity(pulsing ? 0.35 : 0.9)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
    }

    private func bar(widthFraction: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.09))
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Error box

struct ErrorBox: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试", action: onRetry)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }
}
