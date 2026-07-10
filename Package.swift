// swift-tools-version: 6.3

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency=complete"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "LibtorrentSDK",
    platforms: [
        .iOS("26.1"),
        .macOS("26.1"),
    ],
    products: [
        .library(
            name: "LibtorrentSDK",
            targets: ["LibtorrentSDK"]
        ),
        .executable(
            name: "LibtorrentSDKSmokeTests",
            targets: ["LibtorrentSDKSmokeTests"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "LibtorrentNative",
            url: "https://github.com/tryAGI/LibtorrentSDK/releases/download/v0.2.10/LibtorrentNative.xcframework.zip",
            checksum: "7b302d3c57da8f69f6ea6713c1cd37f81c73023025afe5328df35c2b2d7b4d46"
        ),
        .binaryTarget(
            name: "OpenSSL",
            url: "https://github.com/partout-io/openssl-apple/releases/download/3.6.300/openssl.xcframework.zip",
            checksum: "ecb4b3972de7967ccaa37518c502a45b79f7a82bc4e10165455ac96309e64558"
        ),
        .target(
            name: "LibtorrentSDK",
            dependencies: [
                .target(
                    name: "LibtorrentNative",
                    condition: .when(platforms: [.iOS])
                ),
                .target(
                    name: "OpenSSL",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "LibtorrentSDKTests",
            dependencies: ["LibtorrentSDK"],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "LibtorrentSDKSmokeTests",
            dependencies: ["LibtorrentSDK"],
            path: "Tests/LibtorrentSDKSmokeTests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)
