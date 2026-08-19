// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoConnect",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The only external dependency, and the one CLAUDE.md's "ask first" rule was asked about:
        // in-app updates. Sparkle ships as a binary xcframework, so `swift build` links it but
        // cannot embed it; Scripts/make-app.sh copies it into Contents/Frameworks and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        // Pure logic: crypto, models, storage. No UI, fully unit testable.
        .target(
            name: "AutoConnectCore",
            path: "Sources/AutoConnectCore"
        ),
        // The menu bar app itself. Assembled into AutoConnect.app by Scripts/make-app.sh.
        .executableTarget(
            name: "AutoConnect",
            dependencies: [
                "AutoConnectCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AutoConnect",
            // The SVGs are the editable sources for the glyphs; only the PDFs are shipped.
            exclude: ["Resources/on.svg", "Resources/off.svg"],
            // The menu bar glyphs ship as vector PDFs so they stay crisp at any menu bar height
            // and on any display scale.
            resources: [
                .copy("Resources/on.pdf"),
                .copy("Resources/off.pdf"),
                // Alternative sets, chosen in the playground. Same rule throughout: the outline
                // glyph means disconnected, the filled one means a live tunnel.
                .copy("Resources/2-on.pdf"),
                .copy("Resources/2-off.pdf"),
                .copy("Resources/3-on.pdf"),
                .copy("Resources/3-off.pdf"),
                .copy("Resources/globe-on.pdf"),
                .copy("Resources/globe-off.pdf"),
                .copy("Resources/lock-on.pdf"),
                .copy("Resources/lock-off.pdf"),
            ]
        ),
        .testTarget(
            name: "AutoConnectCoreTests",
            dependencies: [
                "AutoConnectCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Tests/AutoConnectCoreTests"
        ),
    ]
)
