// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MacTerminalSSH",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MacTerminalSSH", targets: ["MacTerminalSSH"]),
        .executable(name: "mac-terminal-probe", targets: ["MacTerminalProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.86.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.25.0"),
    ],
    targets: [
        .target(name: "MacTerminalSSH", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        ]),
        .executableTarget(name: "MacTerminalProbe", dependencies: ["MacTerminalSSH"]),
    ]
)
