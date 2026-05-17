// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacHost", targets: ["MacHost"])
    ],
    targets: [
        .executableTarget(
            name: "MacHost",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        )
    ]
)
