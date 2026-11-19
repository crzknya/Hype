// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HyperCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HyperCore", targets: ["HyperCore"])],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.24.0"),
    ],
    targets: [
        .target(
            name: "HyperCore",
            dependencies: [.product(name: "P256K", package: "swift-secp256k1")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HyperCoreTests",
            dependencies: ["HyperCore"],
            resources: [.copy("vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
