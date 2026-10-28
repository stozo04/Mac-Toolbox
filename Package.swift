// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Toolbox",
    platforms: [.macOS(.v14)],
    targets: [
        // libwebp's encoder, vendored so Toolbox can save WebP (ImageIO reads it but cannot write it).
        .target(name: "CWebP", path: "Sources/CWebP",
                exclude: ["AUTHORS", "COPYING", "PATENTS"],
                sources: ["src", "sharpyuv"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .define("NDEBUG")]),
        .executableTarget(name: "Toolbox", dependencies: ["CWebP"], path: "Sources/Toolbox"),
        .testTarget(name: "ToolboxTests", dependencies: ["Toolbox"], path: "Tests/ToolboxTests"),
    ]
)
