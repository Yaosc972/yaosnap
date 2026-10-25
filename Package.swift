// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yaosnap",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "YaosnapCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Yaosnap",
            dependencies: ["YaosnapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "snip",
            dependencies: ["YaosnapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "YaosnapCoreTests",
            dependencies: ["YaosnapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
