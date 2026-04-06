// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TraceView",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TraceView",
            path: "Sources/TraceView"
        )
    ]
)
