// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TraceView",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TraceViewCore",
            path: "Sources/TraceViewCore"
        ),
        .executableTarget(
            name: "TraceView",
            dependencies: ["TraceViewCore"],
            path: "Sources/TraceViewApp"
        ),
        .testTarget(
            name: "TraceViewCoreTests",
            dependencies: ["TraceViewCore"],
            path: "Tests/TraceViewCoreTests"
        ),
    ]
)
