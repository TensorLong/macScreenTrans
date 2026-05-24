// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacScreenTrans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacScreenTransCore", targets: ["MacScreenTransCore"]),
        .executable(name: "MacScreenTrans", targets: ["MacScreenTrans"])
    ],
    targets: [
        .target(
            name: "CMultitouchSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(name: "MacScreenTransCore"),
        .executableTarget(
            name: "MacScreenTrans",
            dependencies: [
                "MacScreenTransCore",
                "CMultitouchSupport"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "MacScreenTransCoreTests",
            dependencies: ["MacScreenTransCore"]
        )
    ]
)
