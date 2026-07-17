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
        .target(
            name: "station_broadcast",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "SRTHaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift")
            ]
        )
    ]
)
