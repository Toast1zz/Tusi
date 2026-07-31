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
    /// TUSI_PREVIEW runs must not hit GitHub, write the real throttle stamp, or paint
    /// network state into screenshots — the preview settings suite is isolated, so the
    /// update checker must be too.
    private let isPreview: Bool

    init(preview: Bool = false) {
        isPreview = preview
    }

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

    /// Manual checks always run; automatic ones respect the throttle. Preview runs
    /// never check at all — screenshots must stay deterministic and offline.
    func check(manual: Bool) {
        guard !isPreview else { return }
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
            // Only a genuinely completed check counts against the throttle. A failed or
            // superseded check leaves lastCheckKey untouched so the next launch retries.
            if activeCheckID == id {
                defaults.set(Date(), forKey: lastCheckKey)
                checkTask = nil
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
    /// Missing components count as 0, so "1.2" == "1.2.0"; a release beats its own
    /// prerelease ("1.6.0" > "1.6.0-beta.1"), and prerelease segments compare by
    /// dot-separated parts, numerically where both are numeric ("1.6.0-beta.2" >
    /// "1.6.0-beta.1").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        Self.compare(candidate, current) > 0
    }

    private static func compare(_ a: String, _ b: String) -> Int {
        let (aCore, aPre) = splitVersion(a)
        let (bCore, bPre) = splitVersion(b)

        let aParts = aCore.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let bParts = bCore.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(aParts.count, bParts.count) {
            let x = i < aParts.count ? aParts[i] : 0
            let y = i < bParts.count ? bParts[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }

        // Release beats prerelease: 1.6.0 > 1.6.0-beta.1.
        if aPre.isEmpty != bPre.isEmpty { return aPre.isEmpty ? 1 : -1 }
        if aPre.isEmpty { return 0 }

        let aSegments = aPre.split(separator: ".").map(String.init)
        let bSegments = bPre.split(separator: ".").map(String.init)
        for i in 0..<max(aSegments.count, bSegments.count) {
            let x = i < aSegments.count ? aSegments[i] : ""
            let y = i < bSegments.count ? bSegments[i] : ""
            if x == y { continue }
            if x.isEmpty { return -1 }  // shorter prerelease sorts first
            if y.isEmpty { return 1 }
            let xn = Int(x), yn = Int(y)
            if let xn, let yn { return xn > yn ? 1 : -1 }  // numeric segments compare numerically
            if xn != nil { return -1 }  // numeric < alphanumeric (semver rule)
            if yn != nil { return 1 }
            return x < y ? -1 : 1  // alphanumeric compares lexically
        }
        return 0
    }

    /// Splits "v1.6.0-beta.1" into ("1.6.0", "beta.1"). Non-numeric release tails
    /// (e.g. "1.6.0-rc" vs "1.6.0") stay out of the core comparison. Build metadata
    /// after "+" is dropped from both sides per semver: "1.6.0+build.5" equals
    /// "1.6.0", never "newer".
    private static func splitVersion(_ version: String) -> (core: String, prerelease: String) {
        let trimmed = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard let dash = trimmed.firstIndex(of: "-") else { return (stripBuildMetadata(trimmed), "") }
        return (stripBuildMetadata(String(trimmed[..<dash])), stripBuildMetadata(String(trimmed[dash...].dropFirst())))
    }

    private static func stripBuildMetadata(_ component: String) -> String {
        guard let plus = component.firstIndex(of: "+") else { return component }
        return String(component[..<plus])
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }
}
