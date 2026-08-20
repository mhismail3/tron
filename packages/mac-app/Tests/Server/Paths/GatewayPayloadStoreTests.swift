import Foundation
import CryptoKit
import Testing
@testable import TronMac

@Suite("Gateway payload store")
struct GatewayPayloadStoreTests {
    @Test("selected paths are isolated by home and channel")
    func selectedPaths() {
        let store = GatewayPayloadStore(home: URL(fileURLWithPath: "/tmp/tron-home", isDirectory: true), channel: "dev")

        #expect(store.currentManifestURL.path == "/tmp/tron-home/gateway/payloads/dev/current.json")
        #expect(store.versionRoot("2025.01").path == "/tmp/tron-home/gateway/payloads/dev/versions/2025.01")
        #expect(GatewayPayloadStore.channel(environment: [:]) == "stable")
        #expect(GatewayPayloadStore.channel(environment: [TronPaths.gatewayChannelEnv: "dev"]) == "dev")
        #expect(GatewayPayloadStore.channel(environment: [TronPaths.gatewayChannelEnv: "../escape"]) == "stable")
    }

    @Test("selection and payload manifests must agree on identity")
    func validatesManifestIdentity() throws {
        let temporary = try TemporaryPayloadDirectory()
        defer { temporary.cleanup() }
        let store = GatewayPayloadStore(home: temporary.root, channel: "dev")
        let version = "2025.01"
        let fingerprint = String(repeating: "a", count: 64)
        let root = store.versionRoot(version)
        try makePayload(root: root, channel: "dev", version: version, fingerprint: fingerprint)
        let manifest = try JSONDecoder().decode(GatewayPayloadManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let selection = GatewayPayloadSelection(channel: "dev", version: version, payloadFingerprint: manifest.payloadFingerprint)
        try write(selection, to: store.currentManifestURL)

        let valid = GatewayPayloadValidator.validateSelection(store: store)
        guard case let .success(result) = valid else {
            Issue.record("expected a complete selected payload to validate: \(valid)")
            return
        }
        #expect(result.manifest.version == version)

        try write(
            GatewayPayloadSelection(channel: "stable", version: version, payloadFingerprint: fingerprint),
            to: store.currentManifestURL
        )
        guard case .failure(.invalidManifest("selection identity")) = GatewayPayloadValidator.validateSelection(store: store) else {
            Issue.record("a selection for another channel must be rejected")
            return
        }
    }

    @Test("invalid external selection falls back without mutating either payload")
    func fallbackPolicy() {
        let bundled = GatewayPayloadValidationResult(
            root: URL(fileURLWithPath: "/bundled/Gateway"),
            manifest: GatewayPayloadManifest(
                channel: "stable",
                version: "1",
                gatewayVersion: "1",
                nodeVersion: "22",
                sourceRevision: "test-revision",
                runtimeEpoch: "test-epoch",
                payloadFingerprint: String(repeating: "b", count: 64)
            )
        )
        let resolved = GatewayPayloadResolver.resolve(
            external: .failure(.invalidManifest("current.json")),
            bundled: .success(bundled)
        )
        #expect(resolved == bundled)
    }

    private func makePayload(root: URL, channel: String, version: String, fingerprint: String) throws {
        let fm = FileManager.default
        let files = [
            "app/dist/index.js": Data(repeating: 0x2f, count: 1_024),
            "app/package.json": Data("{}".utf8),
            "app/package-lock.json": Data("{}".utf8),
            "app/scripts/ensure-node-pty-helper.mjs": Data("// helper".utf8),
            "app/scripts/gateway-payload-deploy.mjs": Data("// update helper".utf8),
        ]
        for (relative, data) in files {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let dependencies = root.appendingPathComponent("app/node_modules", isDirectory: true)
        try fm.createDirectory(at: dependencies, withIntermediateDirectories: true)
        let runtimeDirectory = root.appendingPathComponent("runtime", isDirectory: true)
        try fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        for architecture in ["arm64", "x64"] {
            let runtime = runtimeDirectory.appendingPathComponent("node-\(architecture)", isDirectory: false)
            try Data(repeating: 0x7f, count: 1_048_576).write(to: runtime)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        }
        var lines = Data()
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        func relativePath(_ url: URL) -> String {
            String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(resolvedRoot.path.count + 1))
        }
        let payloadFiles = try fm.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.path.contains("/app/") || $0.path.contains("/runtime/") }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { Data(relativePath($0).utf8).lexicographicallyPrecedes(Data(relativePath($1).utf8)) }
        for file in payloadFiles {
            let relative = relativePath(file)
            let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            lines.append(contentsOf: Data("\(digest)  \(relative)\n".utf8))
        }
        let actualFingerprint = SHA256.hash(data: lines).map { String(format: "%02x", $0) }.joined()
        try write(
            GatewayPayloadManifest(
                channel: channel,
                version: version,
                gatewayVersion: "1",
                nodeVersion: "22",
                sourceRevision: "test-revision",
                runtimeEpoch: "test-epoch",
                payloadFingerprint: actualFingerprint,
                dependencyTreeCoverage: "app/** and runtime/** files and internal symlinks"
            ),
            to: root.appendingPathComponent("manifest.json")
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url)
    }
}

private struct TemporaryPayloadDirectory {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-payload-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
