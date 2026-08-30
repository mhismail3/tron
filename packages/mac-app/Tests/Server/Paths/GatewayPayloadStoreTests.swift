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
        #expect(GatewayPayloadStore.channel(environment: [TronPaths.gatewayChannelEnv: "preview"]) == "stable")
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

    @Test("manifest fields admit launcher maxima and reject over-limit or unsupported values")
    func manifestBoundsAndChannels() throws {
        let temporary = try TemporaryPayloadDirectory()
        defer { temporary.cleanup() }
        let store = GatewayPayloadStore(home: temporary.root, channel: "dev")
        let version = "2025.01"
        let fingerprint = String(repeating: "a", count: 64)
        let maxGatewayVersion = String(repeating: "é", count: 63) + "a"
        let maxNodeVersion = String(repeating: "é", count: 63) + "a"
        let maxSourceRevision = String(repeating: "é", count: 127) + "a"
        let maxRuntimeEpoch = String(repeating: "e", count: GatewayPayloadStore.runtimeEpochComponentLimit)
        let root = store.versionRoot(version)
        try makePayload(
            root: root,
            channel: "dev",
            version: version,
            fingerprint: fingerprint,
            gatewayVersion: maxGatewayVersion,
            nodeVersion: maxNodeVersion,
            sourceRevision: maxSourceRevision,
            runtimeEpoch: maxRuntimeEpoch
        )
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(GatewayPayloadManifest.self, from: Data(contentsOf: manifestURL))
        try write(GatewayPayloadSelection(channel: "dev", version: version, payloadFingerprint: manifest.payloadFingerprint), to: store.currentManifestURL)
        guard case .success = GatewayPayloadValidator.validateSelection(store: store) else {
            Issue.record("launcher maximum UTF-8 field lengths should validate")
            return
        }

        let invalidStore = GatewayPayloadStore(home: temporary.root, channel: "preview")
        guard case .failure(.invalidManifest("channel")) = GatewayPayloadValidator.validateSelection(store: invalidStore) else {
            Issue.record("unsupported selection channels should be rejected")
            return
        }

        let replacement: (String, String) -> GatewayPayloadManifest = { field, value in
            GatewayPayloadManifest(
                channel: field == "channel" ? value : manifest.channel,
                version: manifest.version,
                gatewayVersion: field == "gatewayVersion" ? value : manifest.gatewayVersion,
                protocolVersion: field == "protocolVersion" ? value : manifest.protocolVersion,
                minProtocolVersion: field == "minProtocolVersion" ? value : manifest.minProtocolVersion,
                nodeVersion: field == "nodeVersion" ? value : manifest.nodeVersion,
                sourceRevision: field == "sourceRevision" ? value : manifest.sourceRevision,
                runtimeEpoch: field == "runtimeEpoch" ? value : manifest.runtimeEpoch,
                payloadFingerprint: manifest.payloadFingerprint,
                dependencyTreeCoverage: manifest.dependencyTreeCoverage
            )
        }
        try rewriteManifest(
            GatewayPayloadManifest(
                channel: manifest.channel,
                version: manifest.version,
                gatewayVersion: manifest.gatewayVersion,
                nodeVersion: manifest.nodeVersion,
                sourceRevision: manifest.sourceRevision,
                runtimeEpoch: manifest.runtimeEpoch,
                payloadFingerprint: manifest.payloadFingerprint,
                dependencyTreeCoverage: nil
            ),
            at: manifestURL
        )
        guard case .failure(.invalidManifest) = GatewayPayloadValidator.validateSelection(store: store) else {
            Issue.record("missing fingerprint coverage contract was admitted")
            return
        }

        let overLimitValues = [
            ("gatewayVersion", String(repeating: "é", count: 64)),
            ("nodeVersion", String(repeating: "é", count: 64)),
            ("sourceRevision", String(repeating: "é", count: 128)),
            ("runtimeEpoch", String(repeating: "e", count: GatewayPayloadStore.runtimeEpochComponentLimit + 1)),
            ("protocolVersion", "3"),
            ("minProtocolVersion", "3"),
            ("channel", "preview"),
        ]
        for (field, value) in overLimitValues {
            try rewriteManifest(replacement(field, value), at: manifestURL)
            guard case .failure(.invalidManifest) = GatewayPayloadValidator.validateSelection(store: store) else {
                Issue.record("over-limit or unsupported manifest field was admitted: \(field)")
                return
            }
        }
    }

    @Test("stable push configuration fails closed while dev explicitly allows empty")
    func pushConfigurationAdmission() throws {
        let temporary = try TemporaryPayloadDirectory()
        defer { temporary.cleanup() }
        let cases: [(String, String, Bool)] = [
            ("stable-empty", "TRON_PUSH_SERVICE_ORIGIN =\n", false),
            ("stable-malformed", "TRON_PUSH_SERVICE_ORIGIN = http:/$()/push.example.test\n", false),
            ("stable-duplicate", "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\nTRON_PUSH_SERVICE_ORIGIN = https:/$()/other.example.test\n", false),
            ("dev-empty", "TRON_PUSH_SERVICE_ORIGIN =\n", true),
        ]
        for (version, configuration, shouldPass) in cases {
            let channel = version.hasPrefix("dev") ? "dev" : "stable"
            let root = temporary.root.appendingPathComponent(version, isDirectory: true)
            try makePayload(root: root, channel: channel, version: version, fingerprint: String(repeating: "a", count: 64), pushConfiguration: configuration)
            if shouldPass {
                guard case .success = GatewayPayloadValidator.validate(payloadRoot: root, expectedChannel: channel) else {
                    Issue.record("explicit empty dev configuration should validate")
                    continue
                }
            } else {
                guard case .failure(.incomplete("app/PushService.xcconfig")) = GatewayPayloadValidator.validate(payloadRoot: root, expectedChannel: channel) else {
                    Issue.record("invalid stable configuration was admitted: \(version)")
                    continue
                }
            }
        }

        let missingRoot = temporary.root.appendingPathComponent("stable-missing", isDirectory: true)
        try makePayload(root: missingRoot, channel: "stable", version: "stable-missing", fingerprint: String(repeating: "a", count: 64))
        let missingConfig = missingRoot.appendingPathComponent("app/PushService.xcconfig")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: missingRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: missingConfig.deletingLastPathComponent().path)
        try FileManager.default.removeItem(at: missingConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: missingConfig.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: missingRoot.path)
        guard case .failure(.incomplete("app/PushService.xcconfig")) = GatewayPayloadValidator.validate(payloadRoot: missingRoot, expectedChannel: "stable") else {
            Issue.record("missing stable push configuration was admitted")
            return
        }

        let symlinkRoot = temporary.root.appendingPathComponent("stable-symlink", isDirectory: true)
        try makePayload(root: symlinkRoot, channel: "stable", version: "stable-symlink", fingerprint: String(repeating: "a", count: 64))
        let config = symlinkRoot.appendingPathComponent("app/PushService.xcconfig")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: symlinkRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: config.deletingLastPathComponent().path)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: symlinkRoot.appendingPathComponent("app/package.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: config.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: symlinkRoot.path)
        guard case .failure(.incomplete("app/PushService.xcconfig")) = GatewayPayloadValidator.validate(payloadRoot: symlinkRoot, expectedChannel: "stable") else {
            Issue.record("symlinked stable push configuration was admitted")
            return
        }
    }

    @Test("runtime Node and Pi aliases are exact required command links")
    func runtimeNodeAliasAdmission() throws {
        let temporary = try TemporaryPayloadDirectory()
        defer { temporary.cleanup() }
        for kind in ["missing", "regular", "wrong-target", "absolute-target"] {
            let root = temporary.root.appendingPathComponent("alias-\(kind)", isDirectory: true)
            try makePayload(root: root, channel: "stable", version: kind, fingerprint: String(repeating: "a", count: 64))
            let directory = root.appendingPathComponent("runtime/bin-arm64", isDirectory: true)
            let alias = directory.appendingPathComponent("node", isDirectory: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("runtime").path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try FileManager.default.removeItem(at: alias)
            switch kind {
            case "regular":
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: alias)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: alias.path)
            case "wrong-target":
                try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "../node-x64")
            case "absolute-target":
                try FileManager.default.createSymbolicLink(
                    atPath: alias.path,
                    withDestinationPath: root.appendingPathComponent("runtime/node-arm64").path
                )
            default: break
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("runtime").path)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            guard case .failure(.incomplete) = GatewayPayloadValidator.validate(payloadRoot: root, expectedChannel: "stable") else {
                Issue.record("invalid runtime Node alias was admitted: \(kind)")
                continue
            }
        }
        for kind in ["missing", "regular", "wrong-target", "absolute-target"] {
            let root = temporary.root.appendingPathComponent("pi-alias-\(kind)", isDirectory: true)
            try makePayload(root: root, channel: "stable", version: "pi-\(kind)", fingerprint: String(repeating: "a", count: 64))
            let directory = root.appendingPathComponent("runtime/bin-arm64", isDirectory: true)
            let alias = directory.appendingPathComponent("pi", isDirectory: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("runtime").path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try FileManager.default.removeItem(at: alias)
            switch kind {
            case "regular":
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: alias)
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: alias.path)
            case "wrong-target":
                try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "../node-arm64")
            case "absolute-target":
                try FileManager.default.createSymbolicLink(
                    atPath: alias.path,
                    withDestinationPath: root.appendingPathComponent(GatewayPayloadStore.piCLIRelativePath).path
                )
            default: break
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("runtime").path)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            guard case .failure(.incomplete) = GatewayPayloadValidator.validate(payloadRoot: root, expectedChannel: "stable") else {
                Issue.record("invalid runtime Pi alias was admitted: \(kind)")
                continue
            }
        }
    }

    @Test("writable payload entries are ordinary incomplete external payloads")
    func writablePayloadFallsBack() throws {
        let temporary = try TemporaryPayloadDirectory()
        defer { temporary.cleanup() }
        let store = GatewayPayloadStore(home: temporary.root, channel: "dev")
        let root = store.versionRoot("2025.01")
        try makePayload(root: root, channel: "dev", version: "2025.01", fingerprint: String(repeating: "a", count: 64))
        let manifest = try JSONDecoder().decode(GatewayPayloadManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try write(GatewayPayloadSelection(channel: "dev", version: "2025.01", payloadFingerprint: manifest.payloadFingerprint), to: store.currentManifestURL)
        let writable = root.appendingPathComponent("app/package.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: writable.path)

        guard case .failure(.incomplete) = GatewayPayloadValidator.validateSelection(store: store) else {
            Issue.record("writable payload files must be rejected as incomplete")
            return
        }
        let bundled = GatewayPayloadValidationResult(
            root: URL(fileURLWithPath: "/bundled/Gateway"),
            manifest: GatewayPayloadManifest(channel: "dev", version: "bundled", gatewayVersion: "1", nodeVersion: "22", payloadFingerprint: String(repeating: "b", count: 64))
        )
        #expect(GatewayPayloadResolver.resolve(external: .failure(.incomplete("app/package.json")), bundled: .success(bundled)) == bundled)
    }

    @Test("existing unsafe store roots fail closed instead of selecting the bundle")
    func unsafeStoreRootsFailClosed() throws {
        let temporary = try TemporaryPayloadDirectory()
        defer { temporary.cleanup() }
        let store = GatewayPayloadStore(home: temporary.root, channel: "stable")
        let target = temporary.root.appendingPathComponent("outside-payloads", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.payloadsRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.payloadsRoot, withDestinationURL: target)

        guard case .failure(.unsafePath("payloads root")) = GatewayPayloadValidator.validateSelection(store: store) else {
            Issue.record("an escaping payloads root must be reported as unsafe")
            return
        }
        let bundled = GatewayPayloadValidationResult(
            root: URL(fileURLWithPath: "/bundled/Gateway"),
            manifest: GatewayPayloadManifest(channel: "stable", version: "1", gatewayVersion: "1", nodeVersion: "22", payloadFingerprint: String(repeating: "b", count: 64))
        )
        #expect(GatewayPayloadResolver.resolve(external: .failure(.unsafePath("payloads root")), bundled: .success(bundled)) == nil)
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

    private func makePayload(
        root: URL,
        channel: String,
        version: String,
        fingerprint: String,
        gatewayVersion: String = "1",
        nodeVersion: String = "22",
        sourceRevision: String = "test-revision",
        runtimeEpoch: String = "test-epoch",
        pushConfiguration: String? = nil
    ) throws {
        let fm = FileManager.default
        let files = [
            "app/dist/index.js": Data(repeating: 0x2f, count: 1_024),
            "app/package.json": Data("{}".utf8),
            "app/package-lock.json": Data("{}".utf8),
            "app/PushService.xcconfig": Data((pushConfiguration ?? (channel == "dev"
                ? "TRON_PUSH_SERVICE_ORIGIN =\n"
                : "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\n")).utf8),
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
        let piCLI = root.appendingPathComponent(GatewayPayloadStore.piCLIRelativePath, isDirectory: false)
        try fm.createDirectory(at: piCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: piCLI)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: piCLI.path)
        for architecture in ["arm64", "x64"] {
            let runtime = runtimeDirectory.appendingPathComponent("node-\(architecture)", isDirectory: false)
            try Data(repeating: 0x7f, count: 1_048_576).write(to: runtime)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
            let aliasDirectory = runtimeDirectory.appendingPathComponent("bin-\(architecture)", isDirectory: true)
            try fm.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                atPath: aliasDirectory.appendingPathComponent("node").path,
                withDestinationPath: "../node-\(architecture)"
            )
            try fm.createSymbolicLink(
                atPath: aliasDirectory.appendingPathComponent("pi").path,
                withDestinationPath: GatewayPayloadStore.piAliasTarget
            )
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
        try write(
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

    private func rewriteManifest(_ manifest: GatewayPayloadManifest, at url: URL) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path) }
        try write(manifest, to: url)
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
