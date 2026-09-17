import Foundation
import Darwin

protocol LocalModelRuntime: Sendable {
    func run(_ arguments: [String]) async throws -> (code: Int32, output: String)
    func activeModel() async throws -> String
    func isProcessRunning(_ pid: Int32) async -> Bool
}

struct SystemLocalModelRuntime: LocalModelRuntime {
    func isProcessRunning(_ pid: Int32) async -> Bool {
        !(kill(pid, 0) != 0 && errno == ESRCH)
    }

    func activeModel() async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/models")!)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Models: Decodable { struct Entry: Decodable { let id: String }; let data: [Entry] }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode(Models.self, from: data), entries.data.count == 1 else {
            throw LocalModelError.message("本地服务尚未就绪")
        }
        return URL(fileURLWithPath: entries.data[0].id).lastPathComponent
    }

    func run(_ arguments: [String]) async throws -> (code: Int32, output: String) {
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

/// One transaction holds the lock until either the new model or the restored model is ready.
actor LocalModelService {
    let plistURL: URL
    private let runtime: any LocalModelRuntime
    private var service: String { "gui/\(getuid())/com.tusi.llamaserver" }

    init(plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.tusi.llamaserver.plist"),
         runtime: any LocalModelRuntime = SystemLocalModelRuntime()) {
        self.plistURL = plistURL
        self.runtime = runtime
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

    func selectedModel() throws -> LocalTranslationModel {
        let args = try configuration()["ProgramArguments"] as! [String]
        guard let path = Self.argument("-m", in: args) ?? Self.argument("--model", in: args) else {
            throw LocalModelError.message("服务缺少模型路径")
        }
        return LocalTranslationModel(url: URL(fileURLWithPath: path))
    }

    func activeModel() async throws -> String {
        // An unrelated process on port 8080 is never evidence that our job is running.
        guard try await jobIsLoaded() else { throw LocalModelError.message("本地服务未就绪") }
        return try await runtime.activeModel()
    }

    static func arguments(for model: LocalTranslationModel, original: [String]) throws -> [String] {
        // Never inherit the model's maximum context or the server's auto parallelism.
        // Hy-MT2 declares 262144 tokens, which alone allocates a 16 GiB FP16 KV cache.
        let replaced = Set(["-m", "--model", "--chat-template-file", "--chat-template", "--alias", "-a",
                            "-c", "--ctx-size", "-np", "--parallel", "-cram", "--cache-ram"])
        var args: [String] = []
        var index = 0
        while index < original.count {
            let item = original[index]
            let key = item.components(separatedBy: "=")[0]
            if replaced.contains(key) {
                if !item.contains("=") {
                    guard index + 1 < original.count, !original[index + 1].hasPrefix("--") else {
                        throw LocalModelError.message("本地服务参数不完整")
                    }
                    index += 1
                }
            } else if !["--jinja", "--no-jinja", "--context-shift", "--no-context-shift"].contains(item) {
                args.append(item)
            }
            index += 1
        }
        // Single independent translations need no host-side cache of previous prompts.
        // Disable shifting so exhausting the window cannot silently discard the source.
        args += ["-m", model.url.path, "--ctx-size", "8192", "--parallel", "1",
                 "--cache-ram", "0", "--no-context-shift"]
        if model.id.lowercased().contains("milmmt") {
            let template = model.url.deletingLastPathComponent().appendingPathComponent("milmmt-tusi-chat-template.jinja")
            guard FileManager.default.fileExists(atPath: template.path) else {
                throw LocalModelError.message("MiLMMT 缺少翻译模板")
            }
            args += ["--jinja", "--chat-template-file", template.path]
        }
        return args
    }

    /// The only mutation entry point. On/off, startup reconciliation, model selection
    /// and resource migration all share the same cross-process lock and transaction.
    func reconcile(enabled: Bool, model: LocalTranslationModel? = nil,
                   progress: @Sendable (String) async -> Void) async throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            if enabled { throw LocalModelError.message("未找到可管理的本地翻译服务") }
            return
        }
        let lockURL = plistURL.deletingLastPathComponent().appendingPathComponent(".com.tusi.llamaserver.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LocalModelError.message("无法锁定本地模型服务") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LocalModelError.message("另一个进程正在切换模型") }
        defer { flock(fd, LOCK_UN) }

        let originalData = try Data(contentsOf: plistURL)
        let original = try configuration()
        let selected = try model ?? selectedModel()
        var updated = original
        if enabled || model != nil {
            guard try catalog().contains(where: {
                $0.url.resolvingSymlinksInPath().standardizedFileURL == selected.url.resolvingSymlinksInPath().standardizedFileURL
            }) else { throw LocalModelError.message("模型文件已不存在") }
            updated["ProgramArguments"] = try Self.arguments(for: selected, original: original["ProgramArguments"] as! [String])
        }
        updated["Disabled"] = !enabled
        updated["RunAtLoad"] = enabled
        updated["KeepAlive"] = enabled
        let changed = !NSDictionary(dictionary: original).isEqual(to: updated)
        if changed { try originalData.write(to: plistURL.appendingPathExtension("previous"), options: .atomic) }

        if !enabled {
            // Persist off at both launchd layers. bootout alone would restart at login;
            // killing the PID alone would immediately trigger KeepAlive.
            try await command(["disable", service])
            try write(updated)
            await progress("正在关闭本地模型…")
            try await stop()
            return
        }

        let wasRunning = (try? await activeModel()) != nil
        let oldModel = try selectedModel()
        if !changed, wasRunning, (try? await activeModel()) == selected.id {
            try await command(["enable", service])
            return
        }
        await progress("正在释放当前模型…")
        try await stop()
        do {
            try write(updated)
            try await command(["enable", service])
            await progress(String(format: L("正在加载 %@…"), selected.label))
            try await start()
            try await waitReady(expected: selected.id)
        } catch {
            let cause = error.localizedDescription
            // A failed load may still own memory. Never start recovery before exit.
            do {
                try await stop()
                if wasRunning {
                    try write(original)
                    try await command(["enable", service])
                    try await start()
                    try await waitReady(expected: oldModel.id)
                } else {
                    var stopped = original
                    stopped["Disabled"] = true
                    stopped["RunAtLoad"] = false
                    stopped["KeepAlive"] = false
                    try await command(["disable", service])
                    try write(stopped)
                }
            } catch {
                throw LocalModelError.message(String(format: L("切换失败：%@；恢复失败：%@"), cause, error.localizedDescription))
            }
            throw LocalModelError.message(cause)
        }
    }

    private func write(_ config: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private func command(_ args: [String]) async throws {
        let result = try await runtime.run(args)
        guard result.code == 0 else { throw LocalModelError.message(result.output) }
    }

    private func jobIsLoaded() async throws -> Bool {
        let status = try await runtime.run(["print", service])
        if status.code == 0 { return true }
        guard status.output.contains("Could not find service") else { throw LocalModelError.message(status.output) }
        return false
    }

    private func stop() async throws {
        let status = try await runtime.run(["print", service])
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
        let result = try await runtime.run(["bootout", service])
        guard result.code == 0 else { throw LocalModelError.message(result.output) }
        if let pid {
            for _ in 0..<150 {
                if !(await runtime.isProcessRunning(pid)) { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw LocalModelError.message("原模型尚未退出，已中止加载新模型")
        }
    }

    private func start() async throws {
        let result = try await runtime.run(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.code == 0 else { throw LocalModelError.message(result.output) }
    }

    private func waitReady(expected: String) async throws {
        for _ in 0..<60 {
            if let active = try? await activeModel(), active == expected { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LocalModelError.message("模型加载超时或实际模型不匹配")
    }

}
