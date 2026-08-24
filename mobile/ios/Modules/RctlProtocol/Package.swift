// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RctlProtocol",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RctlProtocol", targets: ["RctlProtocol"]),
    ],
    targets: [
        .target(name: "RctlProtocol"),
        .testTarget(name: "RctlProtocolTests", dependencies: ["RctlProtocol"]),
    ]
)
