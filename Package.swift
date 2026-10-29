// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpaceVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SpaceVoice",
            path: "Sources/SpaceVoice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
