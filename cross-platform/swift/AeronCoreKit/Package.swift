// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AeronCoreKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AeronCoreKit",
            targets: ["AeronCoreKit"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "AeronCoreFFI",
            path: "../AeronCoreFFI.xcframework"
        ),
        .target(
            name: "AeronCoreKit",
            dependencies: ["AeronCoreFFI"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
