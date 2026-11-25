// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GodsView",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GodsView", targets: ["GodsView"])],
    targets: [
        .target(name: "GitHubCore"),
        .executableTarget(name: "GodsView", dependencies: ["GitHubCore"]),
        .testTarget(name: "GitHubCoreTests", dependencies: ["GitHubCore"]),
    ]
)
