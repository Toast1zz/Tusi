import AppKit
import Foundation

enum TextBudget {
    static func prefix(_ text: String, characters: Int, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(bytes))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String((String(data: data, encoding: .utf8) ?? "").prefix(characters))
    }
}

struct TranslationStorage {
    var read: (URL) throws -> Data?
    var write: (Data?, URL) throws -> Void

    static var disk: TranslationStorage {
        TranslationStorage(read: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            return data
        }, write: { data, url in
            if let data {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        })
    }
}

struct TranslationClipboard {
    var write: (String) -> Bool

    static var system: TranslationClipboard {
        TranslationClipboard { text in
            let board = NSPasteboard.general
            let backup = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            board.clearContents()
            if board.setString(text, forType: .string) { return true }
            let items = backup.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            board.clearContents()
            _ = board.writeObjects(items)
            return false
        }
    }
}

struct PartialTranslationFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}
