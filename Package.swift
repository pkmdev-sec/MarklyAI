// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Arcmark",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Arcmark", targets: ["Arcmark"])
    ],
    targets: [
        .executableTarget(name: "Arcmark"),
        .testTarget(name: "ArcmarkTests", dependencies: ["Arcmark"])
    ]
)
