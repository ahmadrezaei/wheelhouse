// swift-tools-version:6.2
// Plugin-free manifest for the vendored SwiftTerm (see VENDORED.md and scripts/vendor-swiftterm.sh).
// Upstream runs SwiftTermBuildInfoGenerator through a build-tool plugin; its two outputs are committed
// under Sources/SwiftTerm/Generated instead, so Xcode never asks to trust a plugin.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: [
                "Mac/README.md",
                "Apple/Metal/Shaders.metal",
                "Documentation.docc",
            ]
        ),
        .testTarget(
            name: "SwiftTermVendorTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermVendorTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
