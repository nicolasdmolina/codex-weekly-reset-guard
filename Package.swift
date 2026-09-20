// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexWeeklyResetGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexWeeklyResetGuardCore", targets: ["CodexWeeklyResetGuardCore"]),
        .executable(name: "CodexWeeklyResetGuard", targets: ["CodexWeeklyResetGuard"]),
    ],
    targets: [
        .target(name: "CodexWeeklyResetGuardCore"),
        .executableTarget(
            name: "CodexWeeklyResetGuard",
            dependencies: ["CodexWeeklyResetGuardCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "CodexWeeklyResetGuardCoreTests",
            dependencies: ["CodexWeeklyResetGuardCore", "CodexWeeklyResetGuard"]
        ),
    ]
)
