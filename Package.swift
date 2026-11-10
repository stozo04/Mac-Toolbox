// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Toolbox",
    platforms: [.macOS(.v14)],
    targets: [
        // libwebp's encoder, vendored so Toolbox can save WebP (ImageIO reads it but cannot write it).
        .target(name: "CWebP", path: "Sources/CWebP",
                exclude: ["AUTHORS", "COPYING", "PATENTS",
                          // libwebp's own autotools build files. Newer SwiftPM hands every file under `sources` to
                          // the compiler, so they must be listed here to keep the vendored tree unmodified.
                          "src/dec/Makefile.am", "src/dsp/Makefile.am", "src/enc/Makefile.am",
                          "src/mux/Makefile.am", "src/utils/Makefile.am",
                          "src/mux/libwebpmux.pc.in", "src/mux/libwebpmux.rc"],
                sources: ["src", "sharpyuv"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .define("NDEBUG")]),
        .executableTarget(name: "Toolbox", dependencies: ["CWebP"], path: "Sources/Toolbox"),
        .testTarget(name: "ToolboxTests", dependencies: ["Toolbox"], path: "Tests/ToolboxTests"),
    ]
)
