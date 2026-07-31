// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tusi",
    // macOS 14 is the real floor: the UI uses `.snappy` animations throughout,
    // which are macOS 14+ APIs (no #available guards at the call sites).
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
