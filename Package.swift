// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DicyaninSimulatorInput",
    platforms: [
        .iOS(.v18),
        .visionOS(.v1),
        .macOS(.v14)
    ],
    products: [
        // Cross-platform wire format + TCP sender/receiver for body + hand poses.
        .library(name: "DicyaninSimInputTransport", targets: ["DicyaninSimInputTransport"]),
        // iPhone runner: ARKit body tracking + Vision hand tracking, broadcast over localhost.
        .library(name: "DicyaninSimInputRunner", targets: ["DicyaninSimInputRunner"]),
        // visionOS consumer: receives poses in the simulator and feeds the mock
        // hand-tracking controller plus a published body skeleton.
        .library(name: "DicyaninSimulatorInput", targets: ["DicyaninSimulatorInput"])
    ],
    dependencies: [
        .package(url: "https://github.com/hunterh37/DicyaninLabsMoCapRecording.git", from: "1.7.2"),
        .package(url: "https://github.com/hunterh37/DicyaninMockHandTracking.git", from: "3.10.0")
    ],
    targets: [
        .target(
            name: "DicyaninSimInputTransport",
            dependencies: [
                .product(name: "DicyaninLabsMoCapRecording", package: "DicyaninLabsMoCapRecording"),
                .product(name: "DicyaninHandTrackingTransport", package: "DicyaninMockHandTracking")
            ]
        ),
        .target(
            name: "DicyaninSimInputRunner",
            dependencies: [
                "DicyaninSimInputTransport",
                .product(name: "DicyaninLabsMoCapRecording", package: "DicyaninLabsMoCapRecording")
            ]
        ),
        .target(
            name: "DicyaninSimulatorInput",
            dependencies: [
                "DicyaninSimInputTransport",
                .product(name: "DicyaninMockHandTracking", package: "DicyaninMockHandTracking")
            ]
        ),
        .testTarget(
            name: "DicyaninSimInputTransportTests",
            dependencies: ["DicyaninSimInputTransport"]
        )
    ]
)
