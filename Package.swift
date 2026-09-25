// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StatusMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StatusMonitor", targets: ["StatusMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "StatusMonitor",
            path: "Sources/StatusMonitor"
        )
    ]
)
