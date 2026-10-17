// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "Quicky",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "QuickyCore", swiftSettings: strict),
        .executableTarget(name: "quicky", dependencies: ["QuickyCore"], swiftSettings: strict),
        .executableTarget(
            name: "QuickyApp",
            dependencies: ["QuickyCore"],
            swiftSettings: strict,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "QuickyCoreTests", dependencies: ["QuickyCore"], swiftSettings: strict),
        .testTarget(name: "QuickyAppTests", dependencies: ["QuickyApp"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
