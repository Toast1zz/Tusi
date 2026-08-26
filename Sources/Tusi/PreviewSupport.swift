import AppKit
import SwiftUI

// MARK: - TUSI_PREVIEW debug mode
//
// Screenshot/inspection runs set TUSI_PREVIEW to a scenario name and pin the panel with
// sample content; TUSI_DARK forces dark appearance and TUSI_SLOWMO stretches animations.
// Kept out of AppDelegate so production launch logic stays readable — this file is never
// entered without the environment variable.

extension AppDelegate {
    /// Runs the debug scenario requested via TUSI_PREVIEW, or does nothing in normal runs.
    func configurePreviewIfNeeded() {
        guard let preview = ProcessInfo.processInfo.environment["TUSI_PREVIEW"] else { return }

        if ProcessInfo.processInfo.environment["TUSI_DARK"] != nil {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        panelState.pinned = true
        panelController.show()
        switch preview {
        case "settings", "update-available", "update-latest", "shortcuts", "settings-local":
            settings.profiles = [
                APIProfile(baseURL: "https://api.deepseek.com", apiKey: "sk-preview", model: "deepseek-chat"),
                APIProfile(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-preview", model: "deepseek/deepseek-chat"),
                APIProfile(baseURL: "http://127.0.0.1:11434/v1", apiKey: "", model: "qwen2.5:7b"),
            ]
            panelState.showSettings = true
            if preview == "update-available" {
                updateChecker.debugSetState(.available(version: "1.3.0", url: URL(string: "https://github.com/Toast1zz/Tusi/releases/latest")!))
            } else if preview == "update-latest" {
                updateChecker.debugSetState(.upToDate)
            } else if preview == "shortcuts" {
                panelState.showShortcuts = true
            } else if preview == "settings-local" {
                panelState.settingsProfileIndex = SettingsStore.localProfileIndex
            }
        case "empty":
            panelState.showSettings = false
        case "quotetest":
            settings.profiles = [
                APIProfile(baseURL: "http://127.0.0.1:8806/v1", apiKey: "sk-x", model: "m"),
                APIProfile(),
                APIProfile(),
            ]
            settings.autoCopy = true
            panelState.showSettings = false
            engine.$history
                .dropFirst()
                .first()
                .sink { [weak self] records in
                    let receipt = "TUSI_HISTORY_COUNT=\(records.count)\n"
                    FileHandle.standardError.write(Data(receipt.utf8))
                    self?.panelState.showHistory = true
                }
                .store(in: &cancellables)
            engine.input = "测试引号"
            engine.translate()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let receipt = "TUSI_STATE=\(self.engine.state) OUTPUT=\(self.engine.output) HISTORY=\(self.engine.history.count)\n"
                FileHandle.standardError.write(Data(receipt.utf8))
            }
        case "corners":
            // Opens settings on a delay so a screenshot burst can catch the
            // transition mid-flight; pair with TUSI_SLOWMO to stretch it out.
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost.",
                toast: nil
            )
            panelState.showSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(Theme.pageTransition) {
                    self.panelState.showSettings = true
                }
            }
        case "reopen":
            panelState.showSettings = false
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost.",
                toast: nil
            )
            panelController.show()
        case "falltest":
            // Primary points at a server that 401s, backup at one that works.
            settings.profiles = [
                APIProfile(baseURL: "http://127.0.0.1:8801/v1", apiKey: "sk-x", model: "broken-model"),
                APIProfile(baseURL: "http://127.0.0.1:8802/v1", apiKey: "sk-x", model: "backup-model"),
                APIProfile(),
            ]
            panelState.showSettings = false
            engine.input = "这句话应该由备用供应商翻译。"
            engine.translate()
        case "waiting":
            panelState.showSettings = false
            engine.debugPreviewTranslating(input: "得益于全新的架构，这次更新带来了显著的性能提升。")
        case "picker", "picker-multi":
            // Inline target-language picker pinned open for screenshot checks;
            // "picker-multi" additionally selects an explicit target (multi mode).
            panelState.showSettings = false
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升，同时保持了完全的向后兼容。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost while remaining fully backward compatible.",
                toast: nil
            )
            if preview == "picker-multi" {
                engine.selectExplicitTarget(.japanese)
            }
            panelState.showLanguagePicker = true
        default:
            panelState.showSettings = false
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升，同时保持了完全的向后兼容。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost while remaining fully backward compatible.",
                toast: preview == "fallback" ? .fellBack
                    : preview == "racewon" ? .raceWon("deepseek")
                    : nil
            )
        }
    }
}
