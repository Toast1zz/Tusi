import AppKit
import SwiftUI

/// Where a field's dropdown hangs from: the field's own AppKit view, so the list opens
/// directly under the field at the field's width, the way a pop-up button's does.
@MainActor
final class DropdownAnchor {
    fileprivate weak var view: NSView?

    struct Item {
        var title: String
        var checked = false
        var action: () -> Void
    }

    /// `items` first; `footer` after a separator (e.g. "清除历史").
    func open(_ items: [Item], footer: [Item] = []) {
        guard let view, let window = view.window, window.isVisible,
              !items.isEmpty || !footer.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Popping up blocks until the menu closes, so the handlers outlive every click.
        var handlers: [MenuHandler] = []
        func add(_ item: Item) {
            let handler = MenuHandler(item.action)
            handlers.append(handler)
            let menuItem = NSMenuItem(title: item.title, action: #selector(MenuHandler.run), keyEquivalent: "")
            menuItem.target = handler
            menuItem.state = item.checked ? .on : .off
            menu.addItem(menuItem)
        }
        items.forEach(add)
        if !footer.isEmpty {
            if !items.isEmpty { menu.addItem(.separator()) }
            footer.forEach(add)
        }
        menu.minimumWidth = view.bounds.width
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
        withExtendedLifetime(handlers) {}
    }
}

private final class MenuHandler: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Registers the view it sits behind as `anchor`'s view.
struct DropdownAnchorView: NSViewRepresentable {
    let anchor: DropdownAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
