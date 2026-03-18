// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RavonCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RavonCore", targets: ["RavonCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.41.0"),
    ],
    targets: [
        .target(
            name: "RavonCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "RavonCoreTests",
            dependencies: ["RavonCore"]
        ),
    ]
)
