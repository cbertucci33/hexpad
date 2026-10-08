// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HexpadKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HexpadKit", targets: ["HexpadKit"])
    ],
    targets: [
        .target(
            name: "HexpadKit",
            path: "Sources/HexpadKit"
        ),
        .testTarget(
            name: "HexpadKitTests",
            dependencies: ["HexpadKit"],
            path: "Tests/HexpadKitTests"
        )
    ]
)
