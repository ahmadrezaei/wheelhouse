// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WheelhouseKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "WheelhouseKit", targets: ["WheelhouseKit"]),
        .library(name: "WheelhouseUI", targets: ["WheelhouseUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    ],
    targets: [
        .target(
            name: "WheelhouseKit",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "WheelhouseUI",
            dependencies: ["WheelhouseKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WheelhouseKitTests",
            dependencies: ["WheelhouseKit", "WheelhouseUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
