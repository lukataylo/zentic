// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Zentic",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ZenticKit", targets: ["ZenticKit"]),
        .executable(name: "ZenticMac", targets: ["ZenticMac"]),
    ],
    dependencies: [
        // Converts Adblock-Plus-syntax filter rules to WKContentRuleList JSON.
        // Swift, so the whole filter pipeline stays in-process — see the plan's
        // "No Rust" note.
        .package(
            url: "https://github.com/AdguardTeam/SafariConverterLib",
            exact: "4.3.0"
        ),
    ],
    targets: [
        // Shared core: all model and policy logic, no UI.
        .target(
            name: "ZenticKit",
            dependencies: [
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib")
            ],
            resources: [
                .copy("Resources/zentic.js"),
                .copy("Blocking/Resources/seed.txt"),
            ]
        ),
        // macOS shell. Custom-drawn AppKit chrome (Arc-style sidebar).
        .executableTarget(
            name: "ZenticMac",
            dependencies: ["ZenticKit"]
        ),
        .testTarget(
            name: "ZenticKitTests",
            dependencies: ["ZenticKit"]
        ),
    ]
)
