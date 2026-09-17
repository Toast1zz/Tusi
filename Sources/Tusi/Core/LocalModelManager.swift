import Foundation
import Combine

struct LocalTranslationModel: Identifiable, Equatable, Sendable {
    let url: URL
    var id: String { url.lastPathComponent }
    var label: String { id.replacingOccurrences(of: ".gguf", with: "") }

    static func discover(in directory: URL) throws -> [Self] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == "gguf"
                && !$0.lastPathComponent.lowercased().contains("mmproj")
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { Self(url: $0) }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

enum LocalModelError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return L(value) }
    }
}

/// The user's persisted choice and the observed runtime are deliberately separate.
/// UI commands are serialized here; launchd mutations are serialized in the service.
@MainActor
final class LocalModelManager: ObservableObject {
    enum State: Equatable {
        case disabled, starting, stopping, ready(String), failed
        var isBusy: Bool { self == .starting || self == .stopping }
    }

    static let shared = LocalModelManager()
    @Published private(set) var models: [LocalTranslationModel] = []
    @Published private(set) var selectedID = ""
    @Published private(set) var state: State = .disabled
    @Published private(set) var error: String?
    private let service: LocalModelService
    private var operationRevision = 0

    init(service: LocalModelService = LocalModelService()) { self.service = service }

    var isSwitching: Bool { state.isBusy }
    var activeID: String { if case .ready(let id) = state { return id }; return "" }
    var status: String {
        switch state {
        case .disabled: return L("已关闭，不占用模型内存")
        case .starting: return L("正在加载本地模型…")
        case .stopping: return L("正在关闭本地模型…")
        case .ready: return L("已就绪，可用于本地翻译")
        case .failed: return L("本地模型状态异常，请重试")
        }
    }

    func prepareAtLaunch(settings: SettingsStore) {
        guard !settings.isPreview else { return }
        transition(enabled: settings.localModelEnabled, model: nil, settings: settings)
    }

    func setEnabled(_ enabled: Bool, settings: SettingsStore) {
        transition(enabled: enabled, model: nil, settings: settings)
    }

    func select(_ id: String, settings: SettingsStore) {
        guard let model = models.first(where: { $0.id == id }) else { return }
        transition(enabled: settings.localModelEnabled, model: model, settings: settings)
    }

    private func transition(enabled: Bool, model: LocalTranslationModel?, settings: SettingsStore) {
        guard !isSwitching else { return }
        operationRevision += 1
        settings.setLocalModelEnabled(enabled)
        settings.setLocalModelReady(false)
        state = enabled ? .starting : .stopping
        error = nil
        // Preview controls are isolated from the user's real launchd service.
        if settings.isPreview {
            if let model { selectedID = model.id }
            state = enabled ? .ready(selectedID) : .disabled
            settings.setLocalModelReady(enabled)
            return
        }
        Task {
            do {
                try await service.reconcile(enabled: enabled, model: model) { _ in }
                await readSelection(settings: settings)
                state = enabled ? .ready(selectedID) : .disabled
                settings.setLocalModelReady(enabled)
            } catch {
                self.error = error.localizedDescription
                await readSelection(settings: settings)
                if enabled, let active = try? await service.activeModel(), active == selectedID {
                    state = .ready(active) // A failed switch restored the previous model.
                    settings.setLocalModelReady(true)
                } else { state = .failed }
            }
        }
    }

    private func readSelection(settings: SettingsStore?) async {
        models = (try? await service.catalog()) ?? []
        selectedID = (try? await service.selectedModel().id) ?? ""
        if let settings, !selectedID.isEmpty {
            settings.profiles[SettingsStore.localProfileIndex].model = selectedID
            settings.profiles[SettingsStore.localProfileIndex].baseURL = "http://127.0.0.1:8080/v1"
            settings.profiles[SettingsStore.localProfileIndex].outputProtocolPreference = .plainText
        }
    }

    /// Refresh is read-only. It can never resurrect a service the user turned off.
    func refresh(settings: SettingsStore? = nil) async {
        guard !isSwitching, settings?.isPreview != true else { return }
        let revision = operationRevision
        let catalog = (try? await service.catalog()) ?? []
        let selected = (try? await service.selectedModel().id) ?? ""
        let active = settings?.localModelEnabled == true ? try? await service.activeModel() : nil
        guard !isSwitching, revision == operationRevision else { return }
        models = catalog
        selectedID = selected
        if let settings, settings.localModelEnabled {
            let ready = active == selected && !selected.isEmpty
            state = ready ? .ready(selected) : .failed
            settings.setLocalModelReady(ready)
        }
    }
}
