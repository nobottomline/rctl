// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RctlClient",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RctlClient", targets: ["RctlClient"]),
    ],
    dependencies: [
        .package(path: "../RctlProtocol"),
    ],
    targets: [
        .target(name: "RctlClient", dependencies: ["RctlProtocol"]),
        .testTarget(name: "RctlClientTests", dependencies: ["RctlClient", "RctlProtocol"]),
    ]
)
