// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TronComputerControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TronComputerControl", targets: ["TronComputerControl"]),
    ],
    targets: [
        .target(name: "TronComputerControl", dependencies: []),
        .testTarget(name: "TronComputerControlTests", dependencies: ["TronComputerControl"]),
    ])
