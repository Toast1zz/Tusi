import AppKit
import SwiftUI

struct SettingsCategoryPicker: NSViewRepresentable {
    @Binding var selection: SettingsSection

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: SettingsSection.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectCategory(_:))
        )
        control.segmentStyle = .automatic
        control.segmentDistribution = .fill
        control.controlSize = .large
        if #available(macOS 26.0, *) {
            control.controlSize = .extraLarge
            control.borderShape = .capsule
            control.prefersCompactControlSizeMetrics = false
        }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { control.role = .tabs }
        #endif
        control.setAccessibilityLabel(L("设置分类"))
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, category) in SettingsSection.allCases.enumerated() {
            control.setLabel(category.title, forSegment: index)
        }
        control.selectedSegment = SettingsSection.allCases.firstIndex(of: selection) ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<SettingsSection>
        init(selection: Binding<SettingsSection>) { self.selection = selection }

        @objc func selectCategory(_ control: NSSegmentedControl) {
            guard SettingsSection.allCases.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = SettingsSection.allCases[control.selectedSegment]
        }
    }
}
