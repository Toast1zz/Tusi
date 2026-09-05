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
                panelState.settingsSection = .general
                updateChecker.debugSetState(.available(version: "1.3.0", url: URL(string: "https://github.com/Toast1zz/Tusi/releases/latest")!))
            } else if preview == "update-latest" {
                panelState.settingsSection = .general
                updateChecker.debugSetState(.upToDate)
            } else if preview == "shortcuts" {
                panelState.settingsSection = .general
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
        case "push":
            // Cycles translator → settings → translator → settings on a timer so the page
            // push can be traced in both directions without driving the UI by hand. Pair
            // with TUSI_SLOWMO=1, which stretches each push to 2.8s.
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost."
            )
            settings.profiles = [
                APIProfile(baseURL: "https://api.deepseek.com", apiKey: "sk-preview", model: "deepseek-chat"),
                APIProfile(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-preview", model: "deepseek/deepseek-chat"),
                APIProfile(baseURL: "http://127.0.0.1:11434/v1", apiKey: "", model: "qwen2.5:7b"),
            ]
            panelState.showSettings = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                let script: [(Double, () -> Void)] = [
                    (4, { self.panelState.showLanguagePicker = true }),   // Disclosure
                    (4, { self.panelState.showLanguagePicker = false }),
                    (4, { self.panelState.showHistory = true }),
                    (4, { self.panelState.showHistory = false }),
                    (4, { self.panelState.showSettings = true }),         // 1st push
                    (5, { self.panelState.showSettings = false }),
                    (5, { self.panelState.showSettings = true }),         // 2nd push
                    (5, { self.panelState.showSettings = false }),
                ]
                for (delay, step) in script {
                    try? await Task.sleep(for: .seconds(delay))
                    step()
                }
            }
        case "corners":
            // Opens settings on a delay so a screenshot burst can catch the
            // transition mid-flight; pair with TUSI_SLOWMO to stretch it out.
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost."
            )
            panelState.showSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.panelState.showSettings = true
            }
        case "reopen":
            panelState.showSettings = false
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost."
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
        case "wrong-language":
            // Reproduces the observed failure: Chinese input, English target, and a
            // model that replied to the remark in Chinese instead of translating it.
            panelState.showSettings = false
            engine.debugPreview(
                input: "真的吗，你们的回答好官方。",
                output: "是的，感谢您的反馈。"
            )
        case "escalated", "provenance", "fallback", "copied":
            // Two answers to one question: the provenance label becomes the switch
            // between them. "provenance" shows the single-answer form instead.
            settings.profiles = [
                APIProfile(baseURL: "https://api.deepseek.com", apiKey: "sk-preview", model: "deepseek-chat"),
                APIProfile(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-preview", model: "deepseek/deepseek-chat"),
                APIProfile(baseURL: "http://127.0.0.1:11434/v1", apiKey: "", model: "qwen2.5:7b"),
            ]
            settings.routeStart = .local
            panelState.showSettings = false
            let local = TranslationEngine.ResultVersion(
                text: "Maybe you could fill in this form every day, for Mitchelle.",
                slot: SettingsStore.localProfileIndex, tier: .local,
                languageMismatch: false, capped: false, afterFailover: false
            )
            let online = TranslationEngine.ResultVersion(
                text: "Perhaps you could fill out this form every day, for Mitchelle.",
                slot: 0, tier: .online,
                languageMismatch: false, capped: false, afterFailover: false
            )
            // "fallback": one online answer that only exists because the primary failed —
            // what the old "已用备用翻译" toast used to say for 2.4 seconds.
            let backup = TranslationEngine.ResultVersion(
                text: online.text, slot: 1, tier: .online,
                languageMismatch: false, capped: false, afterFailover: true
            )
            let shown: [TranslationEngine.ResultVersion]
            switch preview {
            case "escalated": shown = [local, online]
            case "fallback": shown = [backup]
            default: shown = [local]
            }
            engine.debugPreview(
                input: "或许你每天可以填一下这份表格，为了 Mitchelle。",
                output: shown[shown.count - 1].text,
                versions: shown
            )
            if preview == "copied" {
                // Holds the confirmation open long enough to screenshot: the capsule
                // must be exactly as wide here as it is in its resting state.
                Task { @MainActor [weak self] in
                    for _ in 0..<120 {
                        self?.engine.copyOutput()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        case "waiting":
            panelState.showSettings = false
            engine.debugPreviewTranslating(input: "得益于全新的架构，这次更新带来了显著的性能提升。")
        case "picker", "picker-multi":
            // Inline target-language picker pinned open for screenshot checks;
            // "picker-multi" additionally selects an explicit target (multi mode).
            panelState.showSettings = false
            engine.debugPreview(
                input: "得益于全新的架构，这次更新带来了显著的性能提升，同时保持了完全的向后兼容。",
                output: "Thanks to the brand-new architecture, this update delivers a significant performance boost while remaining fully backward compatible."
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
                versions: []
            )
        }
    }
}
