// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RctlRealtime",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RctlRealtime", targets: ["RctlRealtime"]),
    ],
    dependencies: [
        .package(path: "../RctlProtocol"),
        .package(
            url: "https://github.com/livekit/webrtc-xcframework.git",
            exact: "144.7559.14"
        ),
    ],
    targets: [
        .target(
            name: "RctlRealtime",
            dependencies: [
                "RctlProtocol",
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ]
        ),
        .testTarget(name: "RctlRealtimeTests", dependencies: ["RctlRealtime"]),
    ]
)
