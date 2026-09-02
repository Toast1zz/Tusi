import XCTest

/// The motion system's rules, enforced against the source rather than written down and
/// hoped for.
///
/// This exists because the same three defects came back twice. Both previous passes
/// established the right conventions in a document and then fixed the call sites by
/// hand; both times new call sites drifted (a bare `.snappy` here, an ad-hoc
/// `NSAnimationContext` there, a `withAnimation` in an `onHover`), and the drift was
/// invisible until someone re-read all sixty call sites. A grep-shaped test catches it
/// on the commit that introduces it.
///
/// Every rule below has exactly one escape hatch: put `motion-exception:` in a comment
/// on the offending line or the line above it, and say why. `expectedExceptionCount`
/// then makes adding one a deliberate act rather than a quiet one.
final class MotionConventionTests: XCTestCase {
    private struct Violation: CustomStringConvertible {
        let file: String
        let line: Int
        let text: String
        let rule: String
        var description: String { "\(file):\(line) — \(rule)\n    \(text.trimmingCharacters(in: .whitespaces))" }
    }

    /// Repo root, derived from this file's own path so the test works from `swift test`,
    /// Xcode, and CI alike without a hardcoded absolute path.
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TusiTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Tusi")
    }

    /// Where the motion system itself is allowed to say the words everywhere else is
    /// banned from saying.
    private static let motionSystemFile = "Theme.swift"

    /// Deliberate, reviewed exceptions. Raising this number is the point at which
    /// someone has to justify a new one out loud.
    private static let expectedExceptionCount = 3

    private func swiftSources() throws -> [(name: String, path: String, lines: [String])] {
        let root = Self.sourcesRoot
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var files: [(String, String, [String])] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append((url.lastPathComponent, relative, text.components(separatedBy: "\n")))
        }
        XCTAssertGreaterThan(files.count, 10, "Source scan found almost nothing — the path in `sourcesRoot` is probably wrong, which would make every rule below silently pass.")
        return files
    }

    private func isExcepted(_ lines: [String], _ index: Int) -> Bool {
        if lines[index].contains("motion-exception:") { return true }
        if index > 0, lines[index - 1].contains("motion-exception:") { return true }
        return false
    }

    /// Strips `//` comments and string literals so a rule matches real code, not prose
    /// about the rule. (Half this file's own subject matter is discussed in comments in
    /// the very files being scanned.)
    private func code(_ line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" {
                inString.toggle()
                index = line.index(after: index)
                previous = character
                continue
            }
            if !inString, character == "/", line.index(after: index) < line.endIndex, line[line.index(after: index)] == "/" {
                break
            }
            if !inString { out.append(character) }
            previous = character
            index = line.index(after: index)
        }
        return out
    }

    private func scan(
        rule: String,
        skipping skipped: Set<String> = [],
        matching predicate: (String) -> Bool
    ) throws -> [Violation] {
        var violations: [Violation] = []
        for file in try swiftSources() where !skipped.contains(file.name) {
            for (index, line) in file.lines.enumerated() {
                guard predicate(code(line)), !isExcepted(file.lines, index) else { continue }
                violations.append(Violation(file: file.path, line: index + 1, text: line, rule: rule))
            }
        }
        return violations
    }

    private func assertNone(_ violations: [Violation], _ remedy: String) {
        guard !violations.isEmpty else { return }
        XCTFail("\(violations.count) motion-convention violation(s):\n" + violations.map(\.description).joined(separator: "\n") + "\n\n\(remedy)")
    }

    // MARK: - Rules

    /// Rule 2 in `Theme`'s header. An imperative transaction animates everything that
    /// changed on the same runloop turn, including whatever was unrelated — which is how
    /// a control twitches because a translation happened to land while the mouse moved.
    func testNothingUsesWithAnimation() throws {
        assertNone(
            try scan(rule: "withAnimation is banned") { $0.contains("withAnimation") },
            "Declare it instead: `.motion(_:value:)` on the view that should animate, bound to the value that changed."
        )
    }

    /// One vocabulary, one place it is defined. A bare `.animation(...)` at a call site
    /// also bypasses the Reduce Motion check that `MotionModifier` performs.
    func testAnimationsAreDeclaredOnlyThroughMotion() throws {
        assertNone(
            try scan(rule: ".animation(...) must go through .motion(_:value:)", skipping: [Self.motionSystemFile]) {
                $0.contains(".animation(")
            },
            "Use `.motion(.micro/.state/.layout/.page/.selection, value:)`."
        )
    }

    /// Curves and durations are `Theme`'s business. A literal at a call site is how the
    /// app ended up with four different timings for one gesture.
    func testNoRawCurvesOrDurationsOutsideTheme() throws {
        let banned = [".snappy", ".bouncy", ".smooth", ".easeInOut", ".easeOut", ".easeIn", ".spring(", ".timingCurve(", ".linear(duration:"]
        assertNone(
            try scan(rule: "raw animation curve outside Theme", skipping: [Self.motionSystemFile]) { line in
                banned.contains { line.contains($0) }
            },
            "Add a `Theme.Motion` case if a genuinely new kind of motion is needed; otherwise reuse one."
        )
    }

    /// AppKit animation is confined to the two things SwiftUI cannot own: the window's
    /// `alphaValue` (the summon) and its frame (the resize). Both are annotated, both live
    /// in `PanelController`, and both take their duration and curve from `Theme` so they
    /// stay identical to the view-layer animation that caused them. Anything else reaching
    /// for `NSAnimationContext` is a new timeline, which is the defect this whole system
    /// exists to prevent.
    func testAppKitAnimationIsConfinedToTheWindowItself() throws {
        assertNone(
            try scan(rule: "NSAnimationContext is banned (the window mirrors SwiftUI, it does not ease)") {
                $0.contains("NSAnimationContext")
            },
            "Animate it in SwiftUI with `.motion(_:value:)` instead; only the window's own alpha and frame are exempt."
        )
    }

    /// `.transition(.identity)` only ever appeared as a way to opt content *out* of a
    /// timeline it could not keep up with. With one timeline there is nothing to opt out
    /// of, and an identity transition now just means "this pops".
    func testNothingOptsOutWithAnIdentityTransition() throws {
        assertNone(
            try scan(rule: ".transition(.identity) is banned") { $0.contains(".transition(.identity)") },
            "Wrap the content in `Disclosure` so its height animates, instead of making it appear instantly."
        )
    }

    /// Reduce Motion has to establish a SwiftUI dependency to take effect while the panel
    /// is on screen; a direct `NSWorkspace` read does not. The exception is
    /// `PanelController`, which is AppKit and has no environment to read.
    func testViewsReadReduceMotionFromTheEnvironment() throws {
        assertNone(
            try scan(rule: "read Reduce Motion from @Environment, not NSWorkspace", skipping: ["PanelController.swift"]) {
                $0.contains("accessibilityDisplayShouldReduceMotion")
            },
            "Use `@Environment(\\.accessibilityReduceMotion)` so toggling the system setting re-renders immediately."
        )
    }

    /// Exceptions are allowed, but not quietly. If this number moves, the diff has to say
    /// why in the same breath.
    func testExceptionsStayDeliberate() throws {
        var count = 0
        for file in try swiftSources() {
            count += file.lines.filter { $0.contains("motion-exception:") }.count
        }
        XCTAssertEqual(
            count,
            Self.expectedExceptionCount,
            "The number of `motion-exception:` escape hatches changed. Each one opts a call site out of the motion system, so adding or removing one should be a deliberate, explained change — update `expectedExceptionCount` in the same commit that justifies it."
        )
    }
}
