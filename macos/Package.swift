// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncTool",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SyncCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SyncToolAskpass",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SyncTool",
            dependencies: ["SyncCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SyncCoreTests",
            dependencies: ["SyncCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
