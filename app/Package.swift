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
        // Audio engine without any UI: shared by the app and the offline harness.
        .target(
            name: "RVCMacEngine",
            dependencies: ["RVCMacRT", "RVCMacCore"],
            path: "Sources/RVCMacEngine"
        ),
        .executableTarget(
            name: "RVCMac",
            dependencies: ["RVCMacRT", "RVCMacCore", "RVCMacEngine"],
            path: "Sources/RVCMac",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Carbon"),
            ]
        ),
        // Offline harness: the live pipeline on a file, without an audio device (docs/AUDIT_030.md, section 11).
        .executableTarget(
            name: "rvcmac-harness",
            dependencies: ["RVCMacCore", "RVCMacEngine"],
            path: "Sources/RVCMacHarness"
        ),
        .testTarget(
            name: "RVCMacTests",
            dependencies: ["RVCMacRT", "RVCMacCore"],
            path: "Tests/RVCMacTests"
        ),
    ]
)
