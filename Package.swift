// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RavonCore",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "RavonCore",
            targets: ["RavonCore"]
        )
    ],
    targets: [
        .target(
            name: "RavonCore"
        ),
        .testTarget(
            name: "RavonCoreTests",
            dependencies: ["RavonCore"]
        )
    ]
)
