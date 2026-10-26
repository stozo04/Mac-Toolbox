// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Toolbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Toolbox", path: "Sources/Toolbox"),
        .testTarget(name: "ToolboxTests", dependencies: ["Toolbox"], path: "Tests/ToolboxTests"),
    ]
)
