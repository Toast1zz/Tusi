import CryptoKit
import Foundation

actor TranslationProtocolRegistry {
    struct Capability: Codable, Equatable {
        var outputProtocol: TranslationOutputProtocol
        var verifiedAt: Date
        var protocolVersion: Int
    }

    struct Resolution: Equatable, Sendable {
        var outputProtocol: TranslationOutputProtocol
        var cacheHit: Bool
    }

    static let shared = TranslationProtocolRegistry()
    static let protocolVersion = 1
    static let timeToLive: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "translationProtocolCapabilities") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    static func fingerprint(for config: APIConfig) -> String {
        let baseURL = TranslationService.normalizedBaseURLString(config.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let material = "\(baseURL)\n\(model)\n\(config.providerOrderList.joined(separator: ","))\n\(protocolVersion)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func resolve(for config: APIConfig, now: Date = Date()) -> TranslationOutputProtocol {
        resolution(for: config, now: now).outputProtocol
    }

    func resolution(for config: APIConfig, now: Date = Date()) -> Resolution {
        if config.outputProtocolPreference == .plainText {
            return Resolution(outputProtocol: .plainText, cacheHit: false)
        }
        if let capability = validCapability(for: config, now: now) {
            return Resolution(outputProtocol: capability.outputProtocol, cacheHit: true)
        }
        return Resolution(
            outputProtocol: config.requiresAuth ? .strictJSONSchema : .plainText,
            cacheHit: false
        )
    }

    func capability(for config: APIConfig, now: Date = Date()) -> Capability? {
        validCapability(for: config, now: now)
    }

    func record(
        _ outputProtocol: TranslationOutputProtocol,
        for config: APIConfig,
        now: Date = Date()
    ) {
        var capabilities = load()
        let fingerprint = Self.fingerprint(for: config)
        if let existing = capabilities[fingerprint],
           existing.outputProtocol == outputProtocol,
           existing.protocolVersion == Self.protocolVersion,
           now.timeIntervalSince(existing.verifiedAt) >= 0,
           now.timeIntervalSince(existing.verifiedAt) <= Self.timeToLive {
            return
        }
        capabilities[fingerprint] = Capability(
            outputProtocol: outputProtocol,
            verifiedAt: now,
            protocolVersion: Self.protocolVersion
        )
        save(capabilities)
    }

    func invalidate(for config: APIConfig) {
        var capabilities = load()
        capabilities.removeValue(forKey: Self.fingerprint(for: config))
        save(capabilities)
    }

    func removeAll() {
        defaults.removeObject(forKey: storageKey)
    }

    private func validCapability(for config: APIConfig, now: Date) -> Capability? {
        let capability = load()[Self.fingerprint(for: config)]
        guard let capability,
              capability.protocolVersion == Self.protocolVersion,
              now.timeIntervalSince(capability.verifiedAt) >= 0,
              now.timeIntervalSince(capability.verifiedAt) <= Self.timeToLive
        else {
            return nil
        }
        return capability
    }

    private func load() -> [String: Capability] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Capability].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func save(_ capabilities: [String: Capability]) {
        guard let data = try? JSONEncoder().encode(capabilities) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
