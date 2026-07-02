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
        // ObjC shim confining all contact with the private CGVirtualDisplay API.
        .target(name: "CVDShim"),
        .executableTarget(
            name: "MacHost",
            dependencies: ["CVDShim"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        )
    ]
)
