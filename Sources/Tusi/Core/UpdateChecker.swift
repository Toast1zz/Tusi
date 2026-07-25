import AppKit
import Combine

/// Checks GitHub Releases for a newer version. Deliberately does not download or install —
/// the app isn't notarized, so an auto-installer would fight Gatekeeper; instead it points
/// the user at the release page. Compares by semantic version, not string order, so
/// 1.10.0 correctly beats 1.9.0.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    @Published private(set) var state: State = .idle

    private let repo = "neko1chau/Tusi"
    private let defaults = UserDefaults.standard
    private let lastCheckKey = "lastUpdateCheck"
    /// Auto-checks are throttled so a login-item app doesn't hit the API on every launch.
    private let autoInterval: TimeInterval = 6 * 3600

    /// A newer version was found. Kept separate from `state` so a passive surface (the
    /// status-bar menu) can show it even after `state` is reset by a later manual check.
    @Published private(set) var pendingUpdate: (version: String, url: URL)?

    private var checkTask: Task<Void, Never>?
    private var activeCheckID = UUID()

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Forces a state for TUSI_PREVIEW screenshot inspection; never called in normal use.
    func debugSetState(_ state: State) {
        self.state = state
        if case .available(let v, let u) = state { pendingUpdate = (v, u) }
    }

    /// Manual checks always run; automatic ones respect the throttle.
    func check(manual: Bool) {
        if !manual {
            if let last = defaults.object(forKey: lastCheckKey) as? Date,
               Date().timeIntervalSince(last) < autoInterval {
                return
            }
        }

        checkTask?.cancel()
        let checkID = UUID()
        activeCheckID = checkID
        state = .checking
        checkTask = Task { [weak self] in
            await self?.performCheck(id: checkID)
        }
    }

    private func performCheck(id: UUID) async {
        defer {
            if activeCheckID == id {
                defaults.set(Date(), forKey: lastCheckKey)
                checkTask = nil
            }
        }

        guard !Task.isCancelled, activeCheckID == id else { return }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            state = .failed
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, activeCheckID == id else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let release = try? JSONDecoder().decode(Release.self, from: data) else {
                state = .failed
                return
            }
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if Self.isNewer(latest, than: currentVersion),
               let page = URL(string: release.html_url) {
                pendingUpdate = (latest, page)
                state = .available(version: latest, url: page)
            } else {
                pendingUpdate = nil
                state = .upToDate
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard activeCheckID == id else { return }
            state = .failed
        }
    }

    deinit {
        checkTask?.cancel()
    }

    /// True when `candidate` is a strictly higher semantic version than `current`.
    /// Missing components count as 0, so "1.2" == "1.2.0"; non-numeric tails are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }
}
