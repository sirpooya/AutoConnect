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
            // The SVG is the editable source for the glyph; only the PDF is shipped.
            exclude: ["Resources/menubar.svg"],
            // The menu bar glyph ships as vector PDF so it stays crisp at any menu bar height
            // and on any display scale. The SVG is kept alongside it as the editable source.
            resources: [.copy("Resources/menubar.pdf")]
        ),
        .testTarget(
            name: "MacAuthCoreTests",
            dependencies: ["MacAuthCore"],
            path: "Tests/MacAuthCoreTests"
        ),
    ]
)
