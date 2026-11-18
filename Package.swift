// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "macos-use",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(
            name: "MacOSUseKit",
            targets: ["MacOSUseKit"]
        ),
        .executable(
            name: "macos-use",
            targets: ["macos-use"]
        )
    ],
    targets: [
        .target(
            name: "MacOSUseKit",
            path: "Sources/MacOSUseKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "macos-use",
            dependencies: ["MacOSUseKit"],
            path: "Sources/macos-use"
        ),
        .executableTarget(
            name: "macos-use-tests",
            dependencies: ["MacOSUseKit"],
            path: "Tests/MacOSUseTests"
        )
    ]
)
