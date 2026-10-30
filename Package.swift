// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecondWind",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SecondWindCore", targets: ["SecondWindCore"]),
        .executable(name: "SecondWind", targets: ["SecondWind"]),
    ],
    targets: [
        .target(name: "SecondWindCore"),
        .executableTarget(
            name: "SecondWind",
            dependencies: ["SecondWindCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "SecondWindTests",
            dependencies: ["SecondWindCore", "SecondWind"]
        ),
    ]
)
