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
            path: "Sources/MacAuth"
        ),
        .testTarget(
            name: "MacAuthCoreTests",
            dependencies: ["MacAuthCore"],
            path: "Tests/MacAuthCoreTests"
        ),
    ]
)
