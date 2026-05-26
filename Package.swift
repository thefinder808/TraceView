// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TraceView",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "TraceViewCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/TraceViewCore"
        ),
        .executableTarget(
            name: "TraceView",
            dependencies: ["TraceViewCore"],
            path: "Sources/TraceViewApp",
            linkerSettings: [
                // The binary ships inside TraceView.app and needs to find
                // Sparkle.framework at Contents/Frameworks/. dyld searches
                // rpaths relative to the binary's location; without this,
                // the framework resolves only when SwiftPM happens to embed
                // it next to the binary (which it doesn't for SPM-built apps).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "TraceViewCoreTests",
            dependencies: ["TraceViewCore"],
            path: "Tests/TraceViewCoreTests"
        ),
    ]
)
