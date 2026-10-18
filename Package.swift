// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Folio", targets: ["Folio"])
    ],
    targets: [
        .executableTarget(
            name: "Folio",
            path: "Sources/Folio"
        ),
        .testTarget(
            name: "FolioTests",
            dependencies: ["Folio"],
            path: "Tests/FolioTests"
        )
    ]
)
