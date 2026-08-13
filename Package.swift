// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacAuth",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: crypto, models, storage. No UI, fully unit testable.
        .target(
            name: "MacAuthCore",
            path: "Sources/MacAuthCore"
        ),
        // The menu bar app itself. Assembled into MacAuth.app by Scripts/make-app.sh.
        .executableTarget(
            name: "MacAuth",
            dependencies: ["MacAuthCore"],
            path: "Sources/MacAuth",
            // The SVGs are the editable sources for the glyphs; only the PDFs are shipped.
            exclude: ["Resources/on.svg", "Resources/off.svg"],
            // The menu bar glyphs ship as vector PDFs so they stay crisp at any menu bar height
            // and on any display scale.
            resources: [
                .copy("Resources/on.pdf"),
                .copy("Resources/off.pdf"),
            ]
        ),
        .testTarget(
            name: "MacAuthCoreTests",
            dependencies: ["MacAuthCore"],
            path: "Tests/MacAuthCoreTests"
        ),
    ]
)
