// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WheelhouseKit",
    defaultLocalization: "en",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "WheelhouseKit", targets: ["WheelhouseKit"]),
        .library(name: "WheelhouseUI", targets: ["WheelhouseUI"]),
        // Linked only by the Mac app. Every file in it is `#if os(macOS)`.
        .library(name: "WheelhouseDesktop", targets: ["WheelhouseDesktop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    ],
    targets: [
        .target(
            name: "WheelhouseKit",
            dependencies: [.product(name: "Yams", package: "Yams")],
            // Kit runtime data (bundled fallback OpenAPI schemas M7, built-in Rigging packs M13) goes in BundledData/.
            resources: [.copy("BundledData")],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "WheelhouseUI",
            dependencies: ["WheelhouseKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "WheelhouseDesktop",
            dependencies: ["WheelhouseKit"],
            // Real files for M5b's shell-integration scripts (zsh, bash, fish) and other Mac-only data.
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "WheelhouseKitTests",
            dependencies: ["WheelhouseKit", "WheelhouseUI"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WheelhouseDesktopTests",
            dependencies: ["WheelhouseDesktop"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
