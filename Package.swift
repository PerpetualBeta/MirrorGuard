// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MirrorGuard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MirrorGuard",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-framework", "AppKit"]),
                .unsafeFlags(["-framework", "ApplicationServices"]),
                .unsafeFlags(["-framework", "ServiceManagement"]),
            ]
        )
    ]
)
