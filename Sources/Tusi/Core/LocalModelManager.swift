import Foundation
import Combine
import Darwin

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

/// One transaction holds the lock until either the new model or the restored model is ready.
actor LocalModelService {
    let plistURL: URL
    let endpoint = URL(string: "http://127.0.0.1:8080/v1/models")!
    private var service: String { "gui/\(getuid())/com.tusi.llamaserver" }

    init(plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.tusi.llamaserver.plist")) {
        self.plistURL = plistURL
    }

    func configuration() throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
              value["Label"] as? String == "com.tusi.llamaserver",
              let args = value["ProgramArguments"] as? [String],
              args.first.map({ URL(fileURLWithPath: $0).lastPathComponent == "llama-server" }) == true,
              Self.argument("--host", in: args) == "127.0.0.1",
              Self.argument("--port", in: args) == "8080" else {
            throw LocalModelError.message("未找到可管理的本地翻译服务")
        }
        return value
    }

    static func argument(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func catalog() throws -> [LocalTranslationModel] {
        let config = try configuration()
        let args = config["ProgramArguments"] as! [String]
        guard let model = Self.argument("-m", in: args) else { throw LocalModelError.message("服务缺少模型路径") }
        return try LocalTranslationModel.discover(in: URL(fileURLWithPath: model).deletingLastPathComponent())
    }

    func activeModel() async throws -> String {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Models: Decodable { struct Entry: Decodable { let id: String }; let data: [Entry] }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode(Models.self, from: data), entries.data.count == 1 else {
            throw LocalModelError.message("本地服务尚未就绪")
        }
        return URL(fileURLWithPath: entries.data[0].id).lastPathComponent
    }

    static func arguments(for model: LocalTranslationModel, original: [String]) throws -> [String] {
        var args = original
        for key in ["-m", "--model", "--chat-template-file", "--chat-template", "--alias", "-a"] {
            while let index = args.firstIndex(of: key) {
                guard index + 1 < args.count else { throw LocalModelError.message("本地服务参数不完整") }
                args.removeSubrange(index...index + 1)
            }
        }
        args.removeAll { $0 == "--jinja" || $0 == "--no-jinja" }
        args += ["-m", model.url.path]
        if model.id.lowercased().contains("milmmt") {
            let template = model.url.deletingLastPathComponent().appendingPathComponent("milmmt-tusi-chat-template.jinja")
            guard FileManager.default.fileExists(atPath: template.path) else {
                throw LocalModelError.message("MiLMMT 缺少翻译模板")
            }
            args += ["--jinja", "--chat-template-file", template.path]
        }
        return args
    }

    func switchModel(_ model: LocalTranslationModel, progress: @Sendable (String) async -> Void) async throws {
        let lockURL = plistURL.deletingLastPathComponent().appendingPathComponent(".com.tusi.llamaserver.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LocalModelError.message("无法锁定本地模型服务") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LocalModelError.message("另一个进程正在切换模型") }
        defer { flock(fd, LOCK_UN) }
        let original = try Data(contentsOf: plistURL)
        var config = try configuration()
        guard try catalog().contains(model) else { throw LocalModelError.message("模型文件已不存在") }
        config["ProgramArguments"] = try Self.arguments(for: model, original: config["ProgramArguments"] as! [String])
        let updated = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        // Persist recovery data before unloading the currently usable service.
        try original.write(to: plistURL.appendingPathExtension("previous"), options: .atomic)
        await progress("正在释放当前模型…")
        try await stop()
        do {
            try updated.write(to: plistURL, options: .atomic)
            await progress(String(format: L("正在加载 %@…"), model.label))
            try await start()
            try await waitReady(expected: model.id)
        } catch {
            let cause = error.localizedDescription
            await progress("正在恢复原模型…")
            do {
                // A failed load may still own memory. Never start recovery before it exits.
                try await stop()
                try original.write(to: plistURL, options: .atomic)
                try await start()
                let oldArgs = try configuration()["ProgramArguments"] as! [String]
                if let old = Self.argument("-m", in: oldArgs) {
                    try await waitReady(expected: URL(fileURLWithPath: old).lastPathComponent)
                }
            } catch {
                throw LocalModelError.message(String(format: L("切换失败：%@；恢复失败：%@"), cause, error.localizedDescription))
            }
            throw LocalModelError.message(String(format: L("切换失败，已恢复原模型：%@"), cause))
        }
    }

    private func stop() async throws {
        let status = try await Self.run(["print", service])
        if status.code != 0 {
            // Only an absent job is safe to treat as stopped.
            guard status.output.contains("Could not find service") else {
                throw LocalModelError.message(status.output)
            }
            return
        }
        let pid = status.output.split(separator: "\n").compactMap { line -> Int32? in
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
            return parts.count == 2 && parts[0] == "pid" ? Int32(parts[1]) : nil
        }.first
        let result = try await Self.run(["bootout", service])
        guard result.code == 0 else { throw LocalModelError.message(result.output) }
        if let pid {
            for _ in 0..<150 {
                if kill(pid, 0) != 0 && errno == ESRCH { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw LocalModelError.message("原模型尚未退出，已中止加载新模型")
        }
    }

    private func start() async throws {
        let result = try await Self.run(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.code == 0 else { throw LocalModelError.message(result.output) }
    }

    private func waitReady(expected: String) async throws {
        for _ in 0..<60 {
            if let active = try? await activeModel(), active == expected { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LocalModelError.message("模型加载超时或实际模型不匹配")
    }

    private static func run(_ arguments: [String]) async throws -> (code: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }.value
    }
}

@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()
    @Published private(set) var models: [LocalTranslationModel] = []
    @Published private(set) var activeID = ""
    @Published private(set) var isSwitching = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    private let service = LocalModelService()

    func refresh(settings: SettingsStore? = nil) async {
        guard !isSwitching else { return }
        do {
            let catalog = try await service.catalog()
            let active = (try? await service.activeModel()) ?? ""
            guard !isSwitching else { return }
            models = catalog
            activeID = active
            if let settings, !active.isEmpty, catalog.contains(where: { $0.id == active }),
               settings.profiles[SettingsStore.localProfileIndex].baseURL == "http://127.0.0.1:8080/v1" {
                settings.profiles[SettingsStore.localProfileIndex].model = active
            }
            status = active.isEmpty ? L("本地服务未就绪") : String(format: L("当前使用：%@"), active.replacingOccurrences(of: ".gguf", with: ""))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func select(_ id: String, settings: SettingsStore) {
        guard !isSwitching, let model = models.first(where: { $0.id == id }) else { return }
        isSwitching = true
        error = nil
        Task {
            do {
                try await service.switchModel(model) { message in
                    await MainActor.run { self.status = L(message) }
                }
                settings.profiles[SettingsStore.localProfileIndex].model = model.id
                settings.profiles[SettingsStore.localProfileIndex].baseURL = "http://127.0.0.1:8080/v1"
                settings.profiles[SettingsStore.localProfileIndex].outputProtocolPreference = .plainText
            } catch { self.error = error.localizedDescription }
            activeID = (try? await service.activeModel()) ?? ""
            status = activeID.isEmpty ? L("本地服务未就绪") : String(format: L("当前使用：%@"), activeID.replacingOccurrences(of: ".gguf", with: ""))
            isSwitching = false
        }
    }
}
