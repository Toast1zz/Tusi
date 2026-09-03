import AppKit
import SwiftUI

/// Snaps a scrolling text view to whole lines when the user lets go of it.
///
/// Both text areas in the panel are capped at a whole number of lines, and both are
/// aligned at the two positions the app puts them in itself: the top, and the end of the
/// text. Free scrolling is the case neither of those covers — a trackpad leaves the view
/// wherever the gesture stopped, and any offset that is not a multiple of the line step
/// cuts the top and bottom rows through the middle of the glyphs. It shows up as
/// "sometimes it is clipped, sometimes it is not", because whether it clips depends
/// entirely on where the scroll happened to stop.
///
/// AppKit posts `didEndLiveScroll` when a gesture (including its momentum) finishes, so
/// the snap can wait for the scroll to be over instead of fighting it mid-flick.
///
/// This is the one place in the app that reaches into a SwiftUI view's own AppKit
/// hierarchy. There is no supported alternative: `TextEditor` exposes neither its scroll
/// view nor its content offset, `.contentMargins` is ignored by it (measured), and
/// `.scrollTargetBehavior` applies to identifiable scroll content, which a text view has
/// none of. It is written to do nothing at all rather than misbehave if the hierarchy is
/// not what it expects — a future macOS that rebuilds `TextEditor` gets the old,
/// unsnapped behaviour back, not a broken panel.
struct LineSnappingScroll: NSViewRepresentable {
    /// The line grid to snap to: `editorLineStep` for the input, `lineStep` for the result.
    let step: CGFloat

    func makeNSView(context: Context) -> NSView {
        // A zero-size, non-drawing anchor. It exists to be *placed* in the hierarchy
        // beside the scroll view it snaps, nothing more.
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.step = step
        // Deferred: on the pass that creates this view neither it nor the scroll view it
        // claims is necessarily in a window yet, and the claim is geometric. Attaching is
        // idempotent, and SwiftUI calls this again on every update, so a first attempt
        // that lands too early simply gets another one.
        DispatchQueue.main.async {
            context.coordinator.attach(near: view)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(step: step) }

    @MainActor
    final class Coordinator {
        var step: CGFloat
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        init(step: CGFloat) { self.step = step }

        /// Finds the scroll view this anchor belongs to.
        ///
        /// Not by walking up from the anchor: a `.background` is not a sibling of the
        /// thing it backs in the AppKit tree, so the subtree above it does not contain the
        /// scroll view (measured — the first version of this attached to nothing and
        /// silently did nothing at all). It is, however, laid out *on top of* it, and the
        /// panel's two text scrollers never overlap. So collect the candidates from the
        /// window and claim the one this anchor's centre falls inside, which is the
        /// editor or result it was attached to and cannot be the other one.
        func attach(near anchor: NSView) {
            guard observer == nil else { return }
            guard let root = anchor.window?.contentView else { return }
            let centre = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: root)
            var candidates: [NSScrollView] = []
            Self.collectScrollViews(in: root, into: &candidates)
            // Innermost wins. Both text areas are ordinary `NSScrollView`s — the input's
            // holds an `NSTextView`, the result's holds SwiftUI's own document view, so
            // the search cannot be narrowed by document type (measured: requiring an
            // `NSTextView` left the result unclaimed and unsnapped). Nesting is what
            // distinguishes them instead: if several candidates contain this anchor, the
            // smallest is the one it was attached to and the larger ones are its
            // ancestors.
            let found = candidates
                .filter { $0.convert($0.bounds, to: root).contains(centre) }
                .min { lhs, rhs in
                    let l = lhs.bounds, r = rhs.bounds
                    return l.width * l.height < r.width * r.height
                }
            guard let found else { return }
            scrollView = found
            found.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: found,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.snap() }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scrollView = nil
        }

        private static func collectScrollViews(in view: NSView, into found: inout [NSScrollView]) {
            if let scroll = view as? NSScrollView, scroll.documentView != nil {
                found.append(scroll)
            }
            for subview in view.subviews {
                collectScrollViews(in: subview, into: &found)
            }
        }

        /// Rounds the resting offset to the nearest line boundary, within the range the
        /// scroll view actually allows. Never moves by more than half a line, so it reads
        /// as the text settling rather than as the panel scrolling on its own.
        private func snap() {
            guard step > 1, let scrollView else { return }
            let clip = scrollView.contentView
            let current = clip.bounds.origin.y
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let maxOffset = max(0, documentHeight + scrollView.contentInsets.bottom - clip.bounds.height)
            // The extremes are already aligned by construction (the caps are whole line
            // counts) and are also where "show me the very end" lives — snapping away from
            // them would undo the thing the user just asked for.
            guard current > 0.5, current < maxOffset - 0.5 else { return }
            let snapped = min(max((current / step).rounded() * step, 0), maxOffset)
            guard abs(snapped - current) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: snapped))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

extension View {
    /// Applies `LineSnappingScroll` to the text scroll view inside this view.
    func snapsScrollToLines(step: CGFloat) -> some View {
        background(LineSnappingScroll(step: step).frame(width: 0, height: 0))
    }
}
