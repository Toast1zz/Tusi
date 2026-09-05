import Foundation
import Combine

enum SettingsSection: String, CaseIterable {
    case services, translation, general

    var title: String {
        switch self {
        case .services: return L("服务")
        case .translation: return L("翻译")
        case .general: return L("通用")
        }
    }
}

/// Transient UI state shared between the panel controller and SwiftUI views.
@MainActor
final class PanelState: ObservableObject {
    @Published var pinned = false
    @Published var showSettings = false
    @Published var showShortcuts = false
    @Published var settingsProfileIndex = 0
    @Published var settingsSection: SettingsSection = .services
    @Published var settingsAdvancedProfiles: Set<Int> = []
    @Published var recordingShortcut: ShortcutAction?
    @Published var shortcutError: String?
    /// A recorded combo that would take a plain letter or digit away from typing. It is
    /// held here instead of being bound: warning after the fact used to leave the user
    /// with a keyboard that can no longer type that character, and the way out (open the
    /// panel, whose own close key may be the one just broken) is worse than one extra
    /// click. Confirming binds it; dismissing throws it away.
    @Published var pendingBareShortcut: PendingShortcut?
    @Published var globalHotkeyFailed = false
    /// When true, the result area shows translation history instead of the current output.
    @Published var showHistory = false
    /// Inline target-language picker row above the bottom bar, toggled by the
    /// DirectionChip. Transient: collapsed again on every panel show.
    @Published var showLanguagePicker = false
    /// Current panel content width. Starts at 470 and persists across launches.
    @Published var panelWidth: CGFloat = 470
    @Published var availableHeight: CGFloat = 760

    struct PendingShortcut: Equatable {
        let action: ShortcutAction
        let combo: KeyCombo
    }
}

extension Notification.Name {
    static let tusiFocusInput = Notification.Name("tusi.focusInput")
}
