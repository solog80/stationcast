// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "station_broadcast",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "station-broadcast", targets: ["station_broadcast"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift", exact: "2.2.5")
    ],
    targets: [
        .binaryTarget(
            name: "CPJSUA",
            path: "CPJSUA.xcframework"
        ),
        .target(
            name: "StationSip",
            dependencies: ["CPJSUA"],
            path: "Sources/StationSip",
            publicHeadersPath: "include",
            cSettings: [
                .define("PJ_AUTOCONF", to: "1"),
                .define("PJ_IS_LITTLE_ENDIAN", to: "1"),
                .define("PJ_IS_BIG_ENDIAN", to: "0")
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit"),
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "station_broadcast",
            dependencies: [
                "CPJSUA",
                "StationSip",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "SRTHaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift")
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit"),
                .linkedLibrary("c++")
            ]
        )
    ]
)
