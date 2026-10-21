// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PoEPriceCheck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PoEPriceCheck", targets: ["PoEPriceCheck"]),
    ],
    targets: [
        .target(name: "PoECore", path: "Sources/PoECore"),
        .executableTarget(
            name: "PoEPriceCheck",
            dependencies: ["PoECore"],
            path: "Sources/PoEPriceCheck"
        ),
        .executableTarget(
            name: "ocrtool",
            dependencies: ["PoECore"],
            path: "Sources/ocrtool"
        ),
        .testTarget(
            name: "PoECoreTests",
            dependencies: ["PoECore"],
            path: "Tests/PoECoreTests"
        ),
    ]
)
