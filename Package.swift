// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tusi",
    // macOS 14 is the real floor: the UI uses macOS 14 APIs such as `.geometryGroup()`
    // and two-parameter `.onChange` without #available guards.
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tusi",
            path: "Sources/Tusi",
            exclude: ["Resources"],
        ),
        .testTarget(
            name: "TusiTests",
            dependencies: ["Tusi"],
            path: "Tests/TusiTests"
        )
    ]
)
