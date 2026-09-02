// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Transcribe",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Transcribe", targets: ["Transcribe"])
    ],
    targets: [
        .executableTarget(
            name: "Transcribe",
            path: "Sources/Transcribe",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech")
            ]
        )
    ]
)
