// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Quicky",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Quicky",
            path: "Sources/Quicky",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "QuickyTests", dependencies: ["Quicky"], path: "Tests/QuickyTests"),
    ]
)
