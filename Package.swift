// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MarklyAI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Library for bundler to use
        .library(name: "MarklyAICore", targets: ["MarklyAICore"]),
        // Executable for development/testing
        .executable(name: "MarklyAI", targets: ["MarklyAIApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Core library with all app logic
        .target(name: "MarklyAICore", dependencies: ["Sparkle"]),
        // Minimal executable entry point
        .executableTarget(
            name: "MarklyAIApp",
            dependencies: ["MarklyAICore"]
        ),
        .testTarget(
            name: "MarklyAITests",
            dependencies: ["MarklyAICore"]
        )
    ]
)
