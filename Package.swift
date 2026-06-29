// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BitFlow",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "BitFlowCore", targets: ["BitFlowCore"]),
    ],
    targets: [
        .target(
            name: "BitFlowCore",
            path: "BitFlow/Core",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "BitFlowTests",
            dependencies: ["BitFlowCore"],
            path: "BitFlowTests"
        ),
    ]
)
