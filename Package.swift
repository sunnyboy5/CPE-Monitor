// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CPEMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CPEMonitor",
            path: "Sources/CPEMonitor"
        )
    ]
)
