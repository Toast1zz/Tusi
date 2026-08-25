import Foundation
import Combine

/// Transient UI state shared between the panel controller and SwiftUI views.
@MainActor
final class PanelState: ObservableObject {
    @Published var pinned = false
    @Published var showSettings = false
    @Published var showShortcuts = false
    @Published var settingsProfileIndex = 0
    @Published var recordingShortcut: ShortcutAction?
    @Published var shortcutError: String?
    @Published var globalHotkeyFailed = false
    /// When true, the result area shows translation history instead of the current output.
    @Published var showHistory = false
    /// Inline target-language picker row above the bottom bar, toggled by the
    /// DirectionChip. Transient: collapsed again on every panel show.
    @Published var showLanguagePicker = false
    /// Current panel content width. Starts at 470 and persists across launches.
    @Published var panelWidth: CGFloat = 470
}

extension Notification.Name {
    static let tusiFocusInput = Notification.Name("tusi.focusInput")
}
