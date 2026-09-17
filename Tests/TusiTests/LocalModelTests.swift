import XCTest
@testable import Tusi

final class LocalModelTests: XCTestCase {
    func testResourceLimitsReplaceAliasesDuplicatesAndRemainStable() throws {
        let model = LocalTranslationModel(url: URL(fileURLWithPath: "/models/Hy-MT2.gguf"))
        let args = try LocalModelService.arguments(for: model, original: [
            "/bin/llama-server", "--host", "127.0.0.1", "--port", "8080", "-ngl", "99",
            "-m", "old", "-c", "262144", "--ctx-size=131072", "-np", "4", "--parallel=8",
            "-cram", "8192", "--cache-ram=-1", "--context-shift"
        ])
        XCTAssertEqual(LocalModelService.argument("--ctx-size", in: args), "8192")
        XCTAssertEqual(LocalModelService.argument("--parallel", in: args), "1")
        XCTAssertEqual(LocalModelService.argument("--cache-ram", in: args), "0")
        XCTAssertEqual(LocalModelService.argument("-ngl", in: args), "99")
        XCTAssertTrue(args.contains("--no-context-shift"))
        XCTAssertFalse(args.contains("--context-shift"))
        XCTAssertFalse(args.contains("-c"))
        XCTAssertFalse(args.contains("-np"))
        XCTAssertEqual(try LocalModelService.arguments(for: model, original: args), args)
    }

    func testIncompleteResourceArgumentIsRejected() {
        let model = LocalTranslationModel(url: URL(fileURLWithPath: "/models/Hy-MT2.gguf"))
        for tail in [["--ctx-size"], ["--parallel", "--host", "127.0.0.1"]] {
            XCTAssertThrowsError(try LocalModelService.arguments(for: model, original: ["llama-server"] + tail))
        }
    }

    func testSwitchingToHyRemovesMiLMMTTemplateAndDuplicateModelArguments() throws {
        let model = LocalTranslationModel(url: URL(fileURLWithPath: "/models/Hy-MT2-7B-Q4_K_M.gguf"))
        let args = try LocalModelService.arguments(for: model, original: [
            "/bin/llama-server", "-m", "/models/old.gguf", "--host", "127.0.0.1",
            "--port", "8080", "--jinja", "--chat-template-file", "/models/old.jinja"
        ])
        XCTAssertEqual(LocalModelService.argument("-m", in: args), model.url.path)
        XCTAssertFalse(args.contains("--chat-template-file"))
        XCTAssertFalse(args.contains("--jinja"))
        XCTAssertEqual(LocalModelService.argument("--port", in: args), "8080")
    }

    func testMissingMiLMMTTemplateFailsBeforeServiceMutation() {
        let model = LocalTranslationModel(url: URL(fileURLWithPath: "/nonexistent/MiLMMT.gguf"))
        XCTAssertThrowsError(try LocalModelService.arguments(for: model, original: ["llama-server", "-m", "old"]))
    }

    func testDiscoveryExcludesProjectorsAndDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Hy-MT2.gguf", "MiLMMT.gguf", "mmproj-F16.gguf", "notes.txt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.gguf"), withIntermediateDirectories: true)
        XCTAssertEqual(try LocalTranslationModel.discover(in: directory).map(\.id), ["Hy-MT2.gguf", "MiLMMT.gguf"])
    }

    /// Explicitly enabled for this machine's deployment verification, never in normal test runs.
    func testLiveSequentialSwitch() async throws {
        guard ProcessInfo.processInfo.environment["TUSI_TEST_LOCAL_SWITCH"] == "1" else {
            throw XCTSkip("Requires explicit local service integration run")
        }
        let service = LocalModelService()
        let original = try await service.activeModel()
        let models = try await service.catalog()
        let restore = try XCTUnwrap(models.first { $0.id == original })
        do {
            for model in models where model.id != original {
                try await service.reconcile(enabled: true, model: model) { print("LOCAL_SWITCH \($0)") }
                let active = try await service.activeModel()
                XCTAssertEqual(active, model.id)
                print("LOCAL_SWITCH_READY \(active)")
            }
        } catch {
            try await service.reconcile(enabled: true, model: restore) { print("LOCAL_RESTORE \($0)") }
            throw error
        }
        try await service.reconcile(enabled: true, model: restore) { print("LOCAL_RESTORE \($0)") }
        let active = try await service.activeModel()
        XCTAssertEqual(active, original)
    }
}
