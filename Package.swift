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
            url: "https://github.com/tryAGI/LibtorrentSDK/releases/download/v0.2.5/LibtorrentNative.xcframework.zip",
            checksum: "a252e79a755fdf36bbb7d7c7af3f1ff9e9228843d67fda437229e854b4e89654"
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
