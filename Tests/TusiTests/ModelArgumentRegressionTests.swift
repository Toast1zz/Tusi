import Foundation
import XCTest
@testable import Tusi

final class ModelArgumentRegressionTests: XCTestCase {
    func testModelPathPrefersShortArgumentAndRejectsEqualsSyntax() {
        XCTAssertEqual(LocalModelService.modelPath(in: ["--model", "long.gguf", "-m", "short.gguf"]), "short.gguf")
        XCTAssertEqual(LocalModelService.modelPath(in: ["--model", "long.gguf"]), "long.gguf")
        XCTAssertNil(LocalModelService.modelPath(in: ["--model=long.gguf"]))
        XCTAssertNil(LocalModelService.modelPath(in: ["-m"]))
    }

    func testLongModelArgumentMustSupportCatalog() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("test.gguf")
        try Data().write(to: model)
        let plist = dir.appendingPathComponent("service.plist")
        let config: [String: Any] = ["Label": "com.tusi.llamaserver", "ProgramArguments": ["/fake/llama-server", "--host", "127.0.0.1", "--port", "8080", "--model", model.path]]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: plist)
        let service = LocalModelService(plistURL: plist)
        let selected = try await service.selectedModel()
        XCTAssertEqual(selected.id, "test.gguf")
        let catalog = try await service.catalog()
        XCTAssertEqual(catalog.map(\.id), ["test.gguf"])
    }
}
