import Foundation
import Security

enum KeychainError: LocalizedError, Equatable {
    case operationFailed(OSStatus)
    case readFailed(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            return String(format: L("钥匙串保存失败（错误码 %d）"), status)
        case .readFailed(let status):
            return String(format: L("钥匙串读取失败（错误码 %d），请解锁设备后重试"), status)
        case .invalidData:
            return L("钥匙串数据损坏，请在设置中重新保存 API Key")
        }
    }
}

/// Both API keys live in a single Keychain item.
///
/// macOS authorizes access per item, so one item per slot meant one password prompt per
/// slot on every launch. The keys are always read together anyway, so storing them as one
/// JSON blob makes that exactly one prompt.
enum Keychain {
    private static let service = "com.tusi.app"
    private static let account = "apiKeys"
    private static let legacyAccounts = ["apiKey.0", "apiKey.1", "apiKey"]

    /// Keys by slot index. Missing slots are simply absent.
    static func loadKeys() throws -> [Int: String] {
        guard let data = try read(account: account) else { return [:] }
        return try decodeKeys(data)
    }

    static func decodeKeys(_ data: Data) throws -> [Int: String] {
        guard let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw KeychainError.invalidData
        }
        return raw.reduce(into: [:]) { result, pair in
            if let index = Int(pair.key) { result[index] = pair.value }
        }
    }

    static func saveKeys(_ keys: [Int: String]) throws {
        let raw = keys
            .filter { !$0.value.isEmpty }
            .reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }

        guard !raw.isEmpty else {
            try delete(account: account)
            return
        }
        let data = try JSONEncoder().encode(raw)
        try write(data, account: account)
    }

    /// Folds the old one-item-per-slot layout into the combined item. Returns the keys it
    /// recovered, or nil when there was nothing to migrate. Legacy items are deleted only
    /// after the combined write succeeds, so a locked or unavailable Keychain can retry on
    /// the next launch without losing the old credentials.
    static func migrateLegacyKeysIfNeeded() throws -> [Int: String]? {
        var recovered: [Int: String] = [:]
        var found = false
        for legacy in legacyAccounts {
            guard let data = try read(account: legacy) else { continue }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            found = true
            // "apiKey" predates slots entirely and was always the primary.
            let index = legacy == "apiKey" ? 0 : Int(legacy.suffix(1)) ?? 0
            if recovered[index] == nil, !value.isEmpty { recovered[index] = value }
        }
        guard found else { return nil }

        do {
            try saveKeys(recovered)
            legacyAccounts.forEach { try? delete(account: $0) }
        } catch {
            // Keep the recovered values in memory for this run, but leave the legacy
            // records intact so the migration can retry next time.
            Log.keychain.error("legacy API-key migration failed (\(error.localizedDescription, privacy: .public)); will retry on next launch")
        }
        return recovered
    }

    // MARK: - Raw item access

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.readFailed(status) }
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }

    private static func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            // AfterFirstUnlock is the right trade for a login-item app: items stay
            // available after the first unlock of a boot, but a launch that early
            // (before the user unlocks) briefly fails to read. That's expected and
            // recovers on its own — see README's configuration note.
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.operationFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.operationFailed(addStatus)
        }
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }
}
