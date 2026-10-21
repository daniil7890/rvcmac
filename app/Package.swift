// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RVCMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RVCMac",
            path: "Sources/RVCMac",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
            ]
        )
    ]
)
