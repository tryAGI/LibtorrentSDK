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
            url: "https://github.com/tryAGI/LibtorrentSDK/releases/download/v0.2.2/LibtorrentNative.xcframework.zip",
            checksum: "c6f194b50156287a5a82490188e1ae2c0df2d3dd9a85592d8c87d9e0697fa584"
        ),
        .target(
            name: "LibtorrentSDK",
            dependencies: [
                .target(
                    name: "LibtorrentNative",
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
