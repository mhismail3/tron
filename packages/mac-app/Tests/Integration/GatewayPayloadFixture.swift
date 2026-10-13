import CryptoKit
import Foundation
@testable import TronMac

/// Builds an immutable Gateway payload that both the Swift validator and the
/// C launcher admit. `runtimeExecutable` is written as `runtime/node-arm64` and
/// `runtime/node-x64`; the launcher requires at least 1 MiB.
func makeGatewayPayload(
    root: URL,
    channel: String,
    version: String,
    fingerprint: String,
    gatewayVersion: String = "1",
    nodeVersion: String = "22",
    sourceRevision: String = "0123456789abcdef0123456789abcdef01234567",
    runtimeEpoch: String = "01234567-89ab-cdef-0123-456789abcdef",
    pushConfiguration: String? = nil,
    runtimeExecutable: Data = Data(repeating: 0x7f, count: 1_048_576),
    additionalFiles: [(String, Data)] = [],
    additionalSymlinks: [(String, String)] = []
) throws {
    let fm = FileManager.default
    let files: [(String, Data)] = [
        ("app/dist/index.js", Data(repeating: 0x2f, count: 1_024)),
        ("app/package.json", Data("{}".utf8)),
        ("app/package-lock.json", Data("{}".utf8)),
        ("app/PushService.xcconfig", Data((pushConfiguration ?? (channel == "dev"
            ? "TRON_PUSH_SERVICE_ORIGIN =\n"
            : "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\n")).utf8)),
        ("app/scripts/ensure-node-pty-helper.mjs", Data("// helper".utf8)),
        ("app/scripts/gateway-payload-deploy.mjs", Data("// update helper".utf8)),
    ] + additionalFiles
    for (relative, data) in files {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let dependencies = root.appendingPathComponent("app/node_modules", isDirectory: true)
    try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
    let runtimeDirectory = root.appendingPathComponent("runtime", isDirectory: true)
    try fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    let piCLI = root.appendingPathComponent(GatewayPayloadStore.piCLIRelativePath, isDirectory: false)
    let piPackage = root.appendingPathComponent("app/node_modules/@earendil-works/pi-coding-agent", isDirectory: true)
    let piTarget = piPackage.appendingPathComponent("dist/cli.js", isDirectory: false)
    try fm.createDirectory(at: piTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: piCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"name\":\"@earendil-works/pi-coding-agent\",\"bin\":{\"pi\":\"dist/cli.js\"}}".utf8).write(to: piPackage.appendingPathComponent("package.json"))
    try Data("#!/usr/bin/env node\n".utf8).write(to: piTarget)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: piTarget.path)
    try fm.createSymbolicLink(atPath: piCLI.path, withDestinationPath: "../@earendil-works/pi-coding-agent/dist/cli.js")
    let xcodegen = root.appendingPathComponent(GatewayPayloadValidator.xcodegenRelativePath, isDirectory: false)
    try fm.createDirectory(at: xcodegen.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x7f, count: 1_048_576).write(to: xcodegen)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodegen.path)
    let basePreset = root.appendingPathComponent(GatewayPayloadValidator.xcodegenBasePresetRelativePath, isDirectory: false)
    try fm.createDirectory(at: basePreset.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("settings: {}\n".utf8).write(to: basePreset)
    let officialNpmRoot = try bundledNpmRoot()
    guard fm.fileExists(atPath: officialNpmRoot.path) else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: officialNpmRoot.path])
    }
    for architecture in ["arm64", "x64"] {
        let runtime = runtimeDirectory.appendingPathComponent("node-\(architecture)", isDirectory: false)
        try runtimeExecutable.write(to: runtime)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let aliasDirectory = runtimeDirectory.appendingPathComponent("bin-\(architecture)", isDirectory: true)
        try fm.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: aliasDirectory.appendingPathComponent("node").path,
            withDestinationPath: "../node-\(architecture)"
        )
        let npmRoot = runtimeDirectory.appendingPathComponent("npm-\(architecture)", isDirectory: true)
        try fm.copyItem(at: officialNpmRoot, to: npmRoot)
        try fm.createSymbolicLink(
            atPath: aliasDirectory.appendingPathComponent("npm").path,
            withDestinationPath: "../npm-\(architecture)/bin/npm-cli.js"
        )
        try fm.createSymbolicLink(
            atPath: aliasDirectory.appendingPathComponent("pi").path,
            withDestinationPath: GatewayPayloadStore.piAliasTarget
        )
    }
    for (relative, destination) in additionalSymlinks {
        let link = root.appendingPathComponent(relative, isDirectory: false)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }
    var lines = Data()
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    func relativePath(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(resolvedRoot.path.count + 1))
    }
    let payloadFiles: [(URL, String?)] = fm.enumerator(at: root, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }
        .filter { $0.path.contains("/app/") || $0.path.contains("/runtime/") }
        .compactMap { url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return (url, try? fm.destinationOfSymbolicLink(atPath: url.path))
            }
            return (info.st_mode & S_IFMT) == S_IFREG ? (url, nil) : nil
        }
        .sorted { Data(relativePath($0.0).utf8).lexicographicallyPrecedes(Data(relativePath($1.0).utf8)) }
    for (file, linkTarget) in payloadFiles {
        let relative = relativePath(file)
        if let linkTarget {
            let digest = SHA256.hash(data: Data((linkTarget + "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            lines.append(contentsOf: Data("symlink:\(digest)  \(relative)\n".utf8))
        } else {
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            lines.append(contentsOf: Data("\(digest)  \(relative)\n".utf8))
        }
    }
    let actualFingerprint = SHA256.hash(data: lines).map { String(format: "%02x", $0) }.joined()
    try writePayloadDocument(
        GatewayPayloadManifest(
            channel: channel,
            version: version,
            gatewayVersion: gatewayVersion,
            nodeVersion: nodeVersion,
            sourceRevision: sourceRevision,
            runtimeEpoch: runtimeEpoch,
            payloadFingerprint: actualFingerprint,
            dependencyTreeCoverage: GatewayPayloadStore.fingerprintCoverage
        ),
        to: root.appendingPathComponent("manifest.json")
    )
    // The launcher admits only immutable payload trees. Keep the fixture
    // writable while assembling it, then model the published permissions.
    if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [URLResourceKey.isDirectoryKey]) {
        for case let item as URL in enumerator {
            let directory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let mode: NSNumber = directory || item.path.contains("/runtime/") ? 0o555 : 0o444
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: item.path)
        }
    }
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
}

func writePayloadDocument<T: Encodable>(_ value: T, to url: URL) throws {
    let fm = FileManager.default
    let encoder = JSONEncoder()
    // The manifest is written by bundle-gateway.sh and gateway-payload-deploy.mjs,
    // neither of which escapes a solidus, and the launcher's bounded parser
    // rejects every escape sequence. The fixture must model those bytes.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(value).write(to: url)
}

private func bundledNpmRoot() throws -> URL {
    let fm = FileManager.default
    guard let resources = Bundle.main.resourceURL else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "test host resources"])
    }
    let root = resources.appendingPathComponent("Gateway/runtime/npm-arm64", isDirectory: true)
    guard fm.fileExists(atPath: root.appendingPathComponent("package.json").path) else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
    }
    return root
}
