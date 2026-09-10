// swift-tools-version: 6.2

import Foundation
import PackageDescription

// This package is qualification-only. The build gate validates the external
// source closure before resolution; no native executor is added to Tron.app.
guard let source = ProcessInfo.processInfo.environment["TRON_PEEKABOO_SOURCE"],
      source.hasPrefix("/")
else { fatalError("Set TRON_PEEKABOO_SOURCE to the absolute pinned Peekaboo checkout") }

let package = Package(
    name: "TronComputerUseQualification",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "\(source)/Core/PeekabooAutomationKit")],
    targets: [
        .executableTarget(
            name: "TronComputerUseQualification",
            dependencies: [.product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit")]),
        .testTarget(
            name: "TronComputerUseQualificationTests",
            dependencies: ["TronComputerUseQualification", .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit")]),
    ])
