// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacHost", targets: ["MacHost"]),
        .executable(name: "ExtendedDisplayApp", targets: ["ExtendedDisplayApp"])
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
        ),
        // The windowed launcher that ships as Contents/MacOS/ExtendedDisplay: it
        // runs MacHost (and adb for USB) as child processes. SwiftUI/AppKit are
        // linked implicitly by their imports.
        .executableTarget(name: "ExtendedDisplayApp")
    ]
)
