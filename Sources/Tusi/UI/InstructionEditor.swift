import AppKit
import SwiftUI

/// A bounded multiline editor; its natural height participates in settings sizing.
struct InstructionEditor: View {
    @Binding var text: String
    @State private var width: CGFloat = 0

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5)
        let layout = NSLayoutManager()
        let line = ceil(layout.defaultLineHeight(for: font))
        guard width > 10 else { return line * 2 }
        // Measure a separate text network, never the live editor's layoutManager:
        // reading that legacy property would discard TextKit 2 composition.
        let storage = NSTextStorage(string: text + (text.isEmpty || text.hasSuffix("\n") ? " " : ""),
                                    attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return min(line * 6, max(line * 2, ceil(layout.usedRect(for: container).height)))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("例：commit 统一译作「提交」")
                    .font(Theme.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .accessibilityLabel(L("附加要求（可选）"))
                .frame(height: Self.height(for: text, width: width))
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, value in width = value }
        })
    }
}
