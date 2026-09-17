import XCTest
@testable import Tusi

private actor FakeLocalRuntime: LocalModelRuntime {
    var loaded = true
    var calls: [String] = []
    var model = "A.gguf"
    var failNextStart = false
    var failStop = false
    var delayStart = false

    func configure(failStart: Bool = false, failStop: Bool = false, delayStart: Bool = false) {
        self.failNextStart = failStart
        self.failStop = failStop
        self.delayStart = delayStart
    }
    func commands() -> [String] { calls }
    func run(_ arguments: [String]) async throws -> (code: Int32, output: String) {
        calls.append(arguments[0])
        switch arguments[0] {
        case "print": return loaded ? (0, "pid = 123") : (113, "Could not find service")
        case "bootout":
            if failStop { return (1, "stop failed") }
            loaded = false
        case "bootstrap":
            if delayStart { try await Task.sleep(for: .milliseconds(100)) }
            if failNextStart { failNextStart = false; return (1, "start failed") }
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let config = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let args = config["ProgramArguments"] as! [String]
            model = URL(fileURLWithPath: LocalModelService.argument("-m", in: args)!).lastPathComponent
            loaded = true
        default: break
        }
        return (0, "")
    }
    func activeModel() async throws -> String {
        guard loaded else { throw LocalModelError.message("offline") }
        return model
    }
    func isProcessRunning(_ pid: Int32) async -> Bool { loaded }
}

final class LocalModelLifecycleTests: XCTestCase {
    private func fixture() throws -> (URL, LocalModelService, FakeLocalRuntime) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        for name in ["A.gguf", "B.gguf"] { try Data().write(to: directory.appendingPathComponent(name)) }
        let plist = directory.appendingPathComponent("service.plist")
        let config: [String: Any] = ["Label": "com.tusi.llamaserver", "KeepAlive": true, "RunAtLoad": true,
            "ProgramArguments": ["/bin/llama-server", "--host", "127.0.0.1", "--port", "8080",
                                 "-m", directory.appendingPathComponent("A.gguf").path]]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: plist)
        let runtime = FakeLocalRuntime()
        return (directory, LocalModelService(plistURL: plist, runtime: runtime), runtime)
    }

    func testDisablePersistsAtBothLaunchdLayersAndStopsOnlyManagedJob() async throws {
        let (_, service, runtime) = try fixture()
        try await service.reconcile(enabled: false) { _ in }
        let config = try await service.configuration()
        XCTAssertEqual(config["Disabled"] as? Bool, true)
        XCTAssertEqual(config["KeepAlive"] as? Bool, false)
        XCTAssertEqual(config["RunAtLoad"] as? Bool, false)
        let commands = await runtime.commands()
        XCTAssertLessThan(try XCTUnwrap(commands.firstIndex(of: "disable")), try XCTUnwrap(commands.firstIndex(of: "bootout")))
        XCTAssertFalse(commands.contains("bootstrap"))
        // Relaunch and refresh cannot start the job again.
        try await service.reconcile(enabled: false) { _ in }
        _ = try await service.catalog()
        let after = await runtime.commands()
        XCTAssertFalse(after.contains("enable"))
        XCTAssertFalse(after.contains("bootstrap"))
    }

    func testSelectingWhileOffOnlySavesAndEnableLoadsSavedModelOnce() async throws {
        let (directory, service, runtime) = try fixture()
        try await service.reconcile(enabled: false) { _ in }
        let model = LocalTranslationModel(url: directory.appendingPathComponent("B.gguf"))
        try await service.reconcile(enabled: false, model: model) { _ in }
        let selected = try await service.selectedModel()
        XCTAssertEqual(selected, model)
        let before = await runtime.commands()
        XCTAssertFalse(before.contains("bootstrap"))
        try await service.reconcile(enabled: true) { _ in }
        let active = try await service.activeModel()
        XCTAssertEqual(active, "B.gguf")
        try await service.reconcile(enabled: true) { _ in }
        let after = await runtime.commands()
        XCTAssertEqual(after.filter { $0 == "bootstrap" }.count, 1)
        let config = try await service.configuration()
        XCTAssertEqual(config["Disabled"] as? Bool, false)
        let args = try XCTUnwrap(config["ProgramArguments"] as? [String])
        XCTAssertEqual(LocalModelService.argument("--ctx-size", in: args), "8192")
        XCTAssertEqual(LocalModelService.argument("--parallel", in: args), "1")
    }

    func testFailedEnableLeavesNoLoadedJobAndRebootStaysOff() async throws {
        let (_, service, runtime) = try fixture()
        try await service.reconcile(enabled: false) { _ in }
        await runtime.configure(failStart: true)
        do { try await service.reconcile(enabled: true) { _ in }; XCTFail("Must fail") } catch {}
        let config = try await service.configuration()
        XCTAssertEqual(config["Disabled"] as? Bool, true)
        XCTAssertEqual(config["RunAtLoad"] as? Bool, false)
        do { _ = try await service.activeModel(); XCTFail("Must be stopped") } catch {}
        try await service.reconcile(enabled: true) { _ in }
        let active = try await service.activeModel()
        XCTAssertEqual(active, "A.gguf")
    }

    func testFailedSwitchRestoresWorkingModelBeforeReportingError() async throws {
        let (directory, service, runtime) = try fixture()
        try await service.reconcile(enabled: true) { _ in }
        await runtime.configure(failStart: true)
        do {
            try await service.reconcile(enabled: true, model: LocalTranslationModel(url: directory.appendingPathComponent("B.gguf"))) { _ in }
            XCTFail("Must report failed switch")
        } catch {}
        let active = try await service.activeModel()
        let selected = try await service.selectedModel()
        XCTAssertEqual(active, "A.gguf")
        XCTAssertEqual(selected.id, "A.gguf")
    }

    func testStopFailureNeverStartsAnotherModelAndStillDisablesAutostart() async throws {
        let (_, service, runtime) = try fixture()
        await runtime.configure(failStop: true)
        do { try await service.reconcile(enabled: false) { _ in }; XCTFail("Must report failure") } catch {}
        let config = try await service.configuration()
        XCTAssertEqual(config["Disabled"] as? Bool, true)
        let commands = await runtime.commands()
        XCTAssertFalse(commands.contains("bootstrap"))
    }

    func testOverlappingMutationsCannotInterleaveAcrossAwait() async throws {
        let (_, service, runtime) = try fixture()
        await runtime.configure(delayStart: true)
        let first = Task { try await service.reconcile(enabled: true) { _ in } }
        for _ in 0..<100 {
            if await runtime.commands().contains("bootstrap") { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        do { try await service.reconcile(enabled: false) { _ in }; XCTFail("Must reject concurrent mutation") } catch {}
        try await first.value
        let commands = await runtime.commands()
        XCTAssertFalse(commands.contains("disable"))
    }

    @MainActor
    func testManagerKeepsFailedStopVisibleAndRetryRestoresConsistentOffState() async throws {
        let (_, service, runtime) = try fixture()
        let name = "com.tusi.test.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = SettingsStore(preview: false,
            credentialStorage: CredentialStorage(load: { [:] }, save: { _ in }), defaultsOverride: defaults)
        let manager = LocalModelManager(service: service)
        manager.setEnabled(true, settings: settings)
        XCTAssertFalse(settings.localAvailable, "Starting is not ready")
        for _ in 0..<100 where manager.isSwitching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(manager.state, .ready("A.gguf"))
        XCTAssertTrue(settings.localAvailable)
        await runtime.configure(failStop: true)
        manager.setEnabled(false, settings: settings)
        XCTAssertFalse(settings.localAvailable, "Off revokes routing immediately")
        for _ in 0..<100 where manager.isSwitching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(manager.state, .failed)
        XCTAssertNotNil(manager.error)
        XCTAssertFalse(defaults.bool(forKey: "localModelEnabled"))
        await runtime.configure()
        manager.setEnabled(false, settings: settings)
        for _ in 0..<100 where manager.isSwitching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(manager.state, .disabled)
        XCTAssertNil(manager.error)
        await manager.refresh(settings: settings)
        XCTAssertEqual(manager.selectedID, "A.gguf")
        XCTAssertFalse(settings.localAvailable)
    }

    /// Exercises the same controller entry points as the UI against this Mac's managed
    /// service. Preferences/credentials remain isolated; deliberately ends with it OFF.
    @MainActor
    func testLiveManagedLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["TUSI_TEST_LOCAL_LIFECYCLE"] == "1" else {
            throw XCTSkip("Requires explicit local lifecycle integration run")
        }
        let name = "com.tusi.test.live-lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = SettingsStore(preview: false,
            credentialStorage: CredentialStorage(load: { [:] }, save: { _ in }), defaultsOverride: defaults)
        let service = LocalModelService()
        let manager = LocalModelManager(service: service)
        func waitForTransition() async throws {
            for _ in 0..<800 where manager.isSwitching { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertFalse(manager.isSwitching)
            XCTAssertNil(manager.error)
        }
        manager.setEnabled(false, settings: settings)
        try await waitForTransition()
        XCTAssertEqual(manager.state, .disabled)
        let selected = manager.selectedID
        manager.select(selected, settings: settings)
        try await waitForTransition()
        XCTAssertEqual(manager.state, .disabled)
        manager.setEnabled(true, settings: settings)
        try await waitForTransition()
        XCTAssertTrue(settings.localAvailable)
        XCTAssertEqual(manager.activeID, selected)
        let result = try await TranslationService.testConnection(config: settings.config(for: 2))
        XCTAssertGreaterThanOrEqual(result.latencyMilliseconds, 0)
        manager.setEnabled(false, settings: settings)
        try await waitForTransition()
        XCTAssertEqual(manager.state, .disabled)
        let config = try await service.configuration()
        XCTAssertEqual(config["Disabled"] as? Bool, true)
        XCTAssertEqual(config["RunAtLoad"] as? Bool, false)
        let relaunch = LocalModelManager(service: service)
        relaunch.prepareAtLaunch(settings: settings)
        for _ in 0..<100 where relaunch.isSwitching { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(relaunch.state, .disabled)
        XCTAssertEqual(relaunch.selectedID, selected)
        print("LIVE_LIFECYCLE: off -> select while off -> on -> translation -> off -> relaunch off")
    }

    @MainActor
    func testDisabledOrUnreadyLocalSlotCannotEnterAnyRoute() {
        let settings = SettingsStore(preview: true)
        settings.profiles[2] = APIProfile(baseURL: "http://127.0.0.1:8080/v1", model: "local")
        settings.routeStart = .local
        XCTAssertTrue(settings.route.isEmpty)
        settings.setLocalModelEnabled(true)
        XCTAssertTrue(settings.route.isEmpty, "Loading isn't ready")
        settings.setLocalModelReady(true)
        XCTAssertEqual(settings.route.stages.map(\.tier), [.local])
        settings.setLocalModelEnabled(false)
        XCTAssertTrue(settings.route.isEmpty, "No online provider must not implicitly enable local")
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "online")
        XCTAssertEqual(settings.route.stages.map(\.slots), [[0]])
        settings.profiles[0] = settings.profiles[2]
        XCTAssertTrue(settings.route.isEmpty, "Managed endpoint in another slot cannot bypass off")
    }

    @MainActor
    func testEnablementMigrationPreservesActualRouteAndExplicitChoice() {
        for (start, online, expected) in [(RouteStart.online, true, false), (.local, true, true), (.online, false, true)] {
            let name = "com.tusi.test.local.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { UserDefaults.standard.removePersistentDomain(forName: name) }
            XCTAssertEqual(SettingsStore.loadLocalModelEnabled(defaults: defaults, start: start,
                localConfigured: true, onlineConfigured: online), expected)
            defaults.set(false, forKey: "localModelEnabled")
            XCTAssertFalse(SettingsStore.loadLocalModelEnabled(defaults: defaults, start: .local,
                localConfigured: true, onlineConfigured: false))
        }
    }

    @MainActor
    func testDisablingBeforeRetryCannotReuseCapturedLocalRoute() async throws {
        let settings = SettingsStore(preview: true)
        settings.autoCopy = false
        settings.soundEnabled = false
        settings.profiles[2] = APIProfile(baseURL: "http://127.0.0.1:8080/v1", model: "local")
        settings.profiles[0] = APIProfile(baseURL: "https://example.com/v1", apiKey: "k", model: "online")
        settings.routeStart = .local
        settings.setLocalModelEnabled(true)
        settings.setLocalModelReady(true)
        var called: [String] = []
        let engine = TranslationEngine(settings: settings) { _, _, _, _, config in
            called.append(config.model)
            if config.model == "local" {
                settings.setLocalModelEnabled(false)
                return AsyncThrowingStream { $0.finish(throwing: URLError(.networkConnectionLost)) }
            }
            return AsyncThrowingStream { $0.yield("你好"); $0.finish() }
        }
        engine.input = "Hello"
        engine.translate()
        for _ in 0..<200 where engine.state != .done { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(called, ["local", "online"], "The retry must not send a second local request")
        XCTAssertEqual(engine.output, "你好")
    }
}
