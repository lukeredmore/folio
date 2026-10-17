// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenType",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenType", targets: ["OpenType"])
    ],
    targets: [
        .executableTarget(
            name: "OpenType",
            path: "Sources/OpenType"
        ),
        .testTarget(
            name: "OpenTypeTests",
            dependencies: ["OpenType"],
            path: "Tests/OpenTypeTests"
        )
    ]
)
