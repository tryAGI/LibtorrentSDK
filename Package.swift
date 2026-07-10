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
            url: "https://github.com/tryAGI/LibtorrentSDK/releases/download/v0.2.4/LibtorrentNative.xcframework.zip",
            checksum: "d4fab392a3ff3c512cd6b52a6f66dfaa6bbb046e744141e8beb5c0508430ec85"
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
