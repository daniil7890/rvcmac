// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RVCMac",
    platforms: [.macOS(.v14)],
    targets: [
        // Lock-free ring buffer, seqlock clock and atomics for the Core Audio callbacks (C11 atomics).
        .target(
            name: "RVCMacRT",
            path: "Sources/RVCMacRT"
        ),
        // Platform-independent logic: statistics, telemetry records, reports, profiles. Unit-tested.
        .target(
            name: "RVCMacCore",
            path: "Sources/RVCMacCore"
        ),
        .executableTarget(
            name: "RVCMac",
            dependencies: ["RVCMacRT", "RVCMacCore"],
            path: "Sources/RVCMac",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "RVCMacTests",
            dependencies: ["RVCMacRT", "RVCMacCore"],
            path: "Tests/RVCMacTests"
        ),
    ]
)
