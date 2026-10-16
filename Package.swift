// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Assistant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Assistant",
            path: "Sources/Assistant",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "AssistantTests", dependencies: ["Assistant"], path: "Tests/AssistantTests"),
    ]
)
