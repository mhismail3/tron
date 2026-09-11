// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TronComputerControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TronComputerControl", targets: ["TronComputerControl"]),
        .executable(name: "TronNativeCaptureQualification", targets: ["TronNativeCaptureQualification"]),
    ],
    targets: [
        .target(name: "TronComputerControl", dependencies: []),
        .executableTarget(name: "TronNativeCaptureQualification", dependencies: ["TronComputerControl"]),
        .testTarget(name: "TronComputerControlTests", dependencies: ["TronComputerControl"]),
        .testTarget(name: "TronNativeCaptureQualificationTests", dependencies: ["TronNativeCaptureQualification", "TronComputerControl"]),
    ])
