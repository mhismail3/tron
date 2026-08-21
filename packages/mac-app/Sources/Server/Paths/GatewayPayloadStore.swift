import Foundation
import CryptoKit
import Darwin

/// The on-disk contract for externally selected Gateway payloads.
///
/// Updates publish a complete `versions/<version>` directory and atomically
/// replace `current.json`. The wrapper only reads this projection; it never
/// writes sessions, credentials, or any other canonical Gateway state.
struct GatewayPayloadStore {
    static let schema = 1
    static let maxManifestBytes = 64 * 1024
    static let channelComponentLimit = 64
    static let versionComponentLimit = 128
    static let gatewayVersionByteLimit = 127
    static let nodeVersionByteLimit = 127
    static let sourceRevisionByteLimit = 255
    static let runtimeEpochComponentLimit = 127

    let home: URL
    let channel: String

    init(home: URL, channel: String) {
        self.home = home
        self.channel = channel
    }

    var payloadsRoot: URL {
        home.appendingPathComponent("gateway/payloads", isDirectory: true)
    }

    var channelRoot: URL {
        payloadsRoot.appendingPathComponent(channel, isDirectory: true)
    }

    var versionsRoot: URL {
        channelRoot.appendingPathComponent("versions", isDirectory: true)
    }

    /// This file is the sole mutable selection pointer. Deployment replaces it
    /// atomically while retaining the prior selection for rollback.
    var currentManifestURL: URL {
        channelRoot.appendingPathComponent("current.json", isDirectory: false)
    }

    func versionRoot(_ version: String) -> URL {
        versionsRoot.appendingPathComponent(version, isDirectory: true)
    }

    static func channel(environment: [String: String]) -> String {
        let value = environment[TronPaths.gatewayChannelEnv] ?? "stable"
        return validChannel(value) ? value : "stable"
    }

    static func validChannel(_ value: String) -> Bool {
        value == "stable" || value == "dev"
    }

    static func selected(home: URL = TronPaths.tronHome, environment: [String: String]) -> GatewayPayloadStore {
        GatewayPayloadStore(home: home, channel: channel(environment: environment))
    }

    static func validComponent(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength,
              value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a)
                || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e || $0 == 0x2d || $0 == 0x5f
        }
    }
}

struct GatewayPayloadManifest: Codable, Equatable, Sendable {
    static let payloadKind = "tron-gateway-payload"
    static let selectionKind = "tron-gateway-selection"

    let schema: Int
    let kind: String
    let channel: String
    let version: String
    let gatewayVersion: String
    let nodeVersion: String
    let sourceRevision: String?
    let runtimeEpoch: String?
    let payloadFingerprint: String
    let dependencyTreeCoverage: String?

    init(
        schema: Int = GatewayPayloadStore.schema,
        kind: String = GatewayPayloadManifest.payloadKind,
        channel: String,
        version: String,
        gatewayVersion: String,
        nodeVersion: String,
        sourceRevision: String? = nil,
        runtimeEpoch: String? = nil,
        payloadFingerprint: String,
        dependencyTreeCoverage: String? = nil
    ) {
        self.schema = schema
        self.kind = kind
        self.channel = channel
        self.version = version
        self.gatewayVersion = gatewayVersion
        self.nodeVersion = nodeVersion
        self.sourceRevision = sourceRevision
        self.runtimeEpoch = runtimeEpoch
        self.payloadFingerprint = payloadFingerprint
        self.dependencyTreeCoverage = dependencyTreeCoverage
    }
}

struct GatewayPayloadSelection: Codable, Equatable, Sendable {
    let schema: Int
    let kind: String
    let channel: String
    let version: String
    let payloadFingerprint: String

    init(
        schema: Int = GatewayPayloadStore.schema,
        kind: String = GatewayPayloadManifest.selectionKind,
        channel: String,
        version: String,
        payloadFingerprint: String
    ) {
        self.schema = schema
        self.kind = kind
        self.channel = channel
        self.version = version
        self.payloadFingerprint = payloadFingerprint
    }
}

enum GatewayPayloadValidationError: Equatable, Error, Sendable {
    /// The path exists but cannot be trusted as part of the payload store.
    /// Unsafe external paths must not be replaced by the bundled fallback: the
    /// launcher fails closed for the same condition.
    case unsafePath(String)
    case missing(String)
    case notRegularFile(String)
    case tooLarge(String)
    case invalidManifest(String)
    case identityMismatch(String)
    case incomplete(String)
}

struct GatewayPayloadValidationResult: Equatable, Sendable {
    let root: URL
    let manifest: GatewayPayloadManifest
}

/// The launcher and the app share this fail-closed policy: an external
/// selection wins only after bounded prevalidation; otherwise the bundled
/// payload is the safe fallback. Deployment performs complete fingerprint
/// verification before publishing a selection.
enum GatewayPayloadResolver {
    static func resolve(
        external: Result<GatewayPayloadValidationResult, GatewayPayloadValidationError>,
        bundled: Result<GatewayPayloadValidationResult, GatewayPayloadValidationError>
    ) -> GatewayPayloadValidationResult? {
        if case let .success(payload) = external { return payload }
        // Keep the fallback for ordinary absent, malformed, or tampered
        // selections. Existing unsafe roots are a launcher fail-closed signal,
        // not a reason for health to claim the bundled payload is active.
        if case .failure(.unsafePath) = external { return nil }
        if case let .success(payload) = bundled { return payload }
        return nil
    }
}

enum GatewayPayloadValidator {
    static let minimumEntrypointBytes: Int64 = 1_024
    static let minimumRuntimeBytes: Int64 = 1_048_576

    static func validate(
        payloadRoot: URL,
        expectedChannel: String? = nil,
        expectedVersion: String? = nil,
        expectedFingerprint: String? = nil,
        fileManager: FileManager = .default
    ) -> Result<GatewayPayloadValidationResult, GatewayPayloadValidationError> {
        var rootInfo = stat()
        guard lstat(payloadRoot.path, &rootInfo) == 0 else {
            return .failure(.missing("payload root"))
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(.unsafePath("payload root"))
        }
        guard isImmutable(rootInfo) else {
            return .failure(.incomplete("writable payload root"))
        }
        let root = payloadRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(root, fileManager: fileManager) else {
            return .failure(.missing("payload root"))
        }
        guard immutableTree(root, under: root, fileManager: fileManager) else {
            return .failure(.incomplete("writable payload entry"))
        }

        guard let manifestURL = containedRegularURL("manifest.json", under: root, directory: false),
              let data = boundedData(at: manifestURL, fileManager: fileManager) else {
            return .failure(.missing("manifest.json"))
        }
        let manifest: GatewayPayloadManifest
        do {
            manifest = try JSONDecoder().decode(GatewayPayloadManifest.self, from: data)
        } catch {
            return .failure(.invalidManifest("manifest.json"))
        }
        guard manifest.schema == GatewayPayloadStore.schema,
              manifest.kind == GatewayPayloadManifest.payloadKind,
              GatewayPayloadStore.validChannel(manifest.channel),
              GatewayPayloadStore.validComponent(manifest.version, maximumLength: GatewayPayloadStore.versionComponentLimit),
              !manifest.gatewayVersion.isEmpty,
              manifest.gatewayVersion.utf8.count <= GatewayPayloadStore.gatewayVersionByteLimit,
              !manifest.nodeVersion.isEmpty,
              manifest.nodeVersion.utf8.count <= GatewayPayloadStore.nodeVersionByteLimit,
              manifest.sourceRevision.map({ !$0.isEmpty && $0.utf8.count <= GatewayPayloadStore.sourceRevisionByteLimit }) == true,
              manifest.runtimeEpoch.map({ GatewayPayloadStore.validComponent($0, maximumLength: GatewayPayloadStore.runtimeEpochComponentLimit) }) == true,
              isFingerprint(manifest.payloadFingerprint) else {
            return .failure(.invalidManifest("manifest identity"))
        }
        if let expectedChannel, manifest.channel != expectedChannel {
            return .failure(.identityMismatch("channel"))
        }
        if let expectedVersion, manifest.version != expectedVersion {
            return .failure(.identityMismatch("version"))
        }
        if let expectedFingerprint, manifest.payloadFingerprint != expectedFingerprint {
            return .failure(.identityMismatch("payload fingerprint"))
        }

        let requiredFiles: [(String, Int64)] = [
            ("app/dist/index.js", minimumEntrypointBytes),
            ("app/package.json", 1),
            ("app/package-lock.json", 1),
            ("app/scripts/ensure-node-pty-helper.mjs", 1),
            ("app/scripts/gateway-payload-deploy.mjs", 1),
        ]
        for (relativePath, minimumBytes) in requiredFiles {
            guard let url = containedRegularURL(relativePath, under: root, directory: false),
                  usableFile(url, minimumBytes: minimumBytes, fileManager: fileManager) else {
                return .failure(.incomplete(relativePath))
            }
        }
        guard let dependencies = containedRegularURL("app/node_modules", under: root, directory: true),
              isDirectory(dependencies, fileManager: fileManager) else {
            return .failure(.incomplete("app/node_modules"))
        }

        for architecture in ["arm64", "x64"] {
            guard let runtime = containedRegularURL("runtime/node-\(architecture)", under: root, directory: false),
                  usableFile(runtime, minimumBytes: minimumRuntimeBytes, fileManager: fileManager),
                  fileManager.isExecutableFile(atPath: runtime.path) else {
                return .failure(.incomplete("runtime/node-\(architecture)"))
            }
        }
        guard let actualFingerprint = payloadFingerprint(root, fileManager: fileManager) else {
            return .failure(.incomplete("payload fingerprint"))
        }
        guard actualFingerprint == manifest.payloadFingerprint else {
            return .failure(.identityMismatch("payload fingerprint"))
        }
        return .success(GatewayPayloadValidationResult(root: root, manifest: manifest))
    }

    static func validateSelection(
        store: GatewayPayloadStore,
        fileManager: FileManager = .default
    ) -> Result<GatewayPayloadValidationResult, GatewayPayloadValidationError> {
        guard GatewayPayloadStore.validChannel(store.channel) else {
            return .failure(.invalidManifest("channel"))
        }
        for (url, label) in [(store.payloadsRoot, "payloads root"), (store.channelRoot, "channel root"), (store.versionsRoot, "versions root")] {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                return .failure(.missing("payload store roots"))
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                return .failure(.unsafePath(label))
            }
        }
        var currentInfo = stat()
        guard lstat(store.currentManifestURL.path, &currentInfo) == 0 else {
            return .failure(.missing("current.json"))
        }
        guard (currentInfo.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.unsafePath("current.json"))
        }
        let payloadsRoot = store.payloadsRoot.resolvingSymlinksInPath().standardizedFileURL
        let channelRoot = store.channelRoot.resolvingSymlinksInPath().standardizedFileURL
        let versionsRoot = store.versionsRoot.resolvingSymlinksInPath().standardizedFileURL
        let expectedPayloadsRoot = store.payloadsRoot.standardizedFileURL
        let expectedChannelRoot = store.channelRoot.standardizedFileURL
        let expectedVersionsRoot = store.versionsRoot.standardizedFileURL
        guard payloadsRoot == expectedPayloadsRoot else {
            return .failure(.unsafePath("payloads root"))
        }
        guard channelRoot == expectedChannelRoot, isContained(channelRoot, under: payloadsRoot) else {
            return .failure(.unsafePath("channel root"))
        }
        guard versionsRoot == expectedVersionsRoot, isContained(versionsRoot, under: channelRoot) else {
            return .failure(.unsafePath("versions root"))
        }
        guard let currentManifest = containedURL("current.json", under: channelRoot),
              isContained(currentManifest.resolvingSymlinksInPath().standardizedFileURL, under: channelRoot) else {
            return .failure(.unsafePath("current.json"))
        }
        guard let data = boundedData(at: currentManifest, fileManager: fileManager) else {
            return .failure(.missing("current.json"))
        }
        let selection: GatewayPayloadSelection
        do {
            selection = try JSONDecoder().decode(GatewayPayloadSelection.self, from: data)
        } catch {
            return .failure(.invalidManifest("current.json"))
        }
        guard selection.schema == GatewayPayloadStore.schema,
              selection.kind == GatewayPayloadManifest.selectionKind,
              selection.channel == store.channel,
              GatewayPayloadStore.validComponent(selection.version, maximumLength: GatewayPayloadStore.versionComponentLimit),
              isFingerprint(selection.payloadFingerprint) else {
            return .failure(.invalidManifest("selection identity"))
        }
        var versionInfo = stat()
        let selectedVersionRoot = store.versionRoot(selection.version)
        guard lstat(selectedVersionRoot.path, &versionInfo) == 0 else {
            return .failure(.missing("version root"))
        }
        guard (versionInfo.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(.unsafePath("version root"))
        }
        let versionRoot = selectedVersionRoot.resolvingSymlinksInPath().standardizedFileURL
        guard versionRoot == selectedVersionRoot.standardizedFileURL,
              isContained(versionRoot, under: versionsRoot) else {
            return .failure(.unsafePath("version root"))
        }
        return validate(
            payloadRoot: versionRoot,
            expectedChannel: store.channel,
            expectedVersion: selection.version,
            expectedFingerprint: selection.payloadFingerprint,
            fileManager: fileManager
        )
    }

    private static func boundedData(at url: URL, fileManager: FileManager) -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Int64(GatewayPayloadStore.maxManifestBytes) else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Matches hash-gateway-payload.sh: sorted UTF-8 relative paths, each
    /// regular-file `sha256  path\\n` or symlink `symlink:sha256(target + LF)  path\\n` line,
    /// then SHA-256 of the complete line stream.
    private static func payloadFingerprint(_ root: URL, fileManager: FileManager) -> String? {
        var files: [(String, URL, String?)] = []
        for prefix in ["app", "runtime"] {
            guard collectRegularFiles(root.appendingPathComponent(prefix, isDirectory: true), relativePrefix: prefix, root: root, files: &files) else { return nil }
        }
        files.sort { Data($0.0.utf8).lexicographicallyPrecedes(Data($1.0.utf8)) }
        var lines = Data()
        for (relativePath, url, linkTarget) in files {
            if let linkTarget {
                let targetDigest = SHA256.hash(data: Data((linkTarget + "\n").utf8)).map { String(format: "%02x", $0) }.joined()
                lines.append(contentsOf: Data("symlink:\(targetDigest)  \(relativePath)\n".utf8))
            } else {
                guard let data = try? Data(contentsOf: url) else { return nil }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                lines.append(contentsOf: Data("\(digest)  \(relativePath)\n".utf8))
            }
        }
        return SHA256.hash(data: lines).map { String(format: "%02x", $0) }.joined()
    }

    private static func immutableTree(_ url: URL, under root: URL, fileManager: FileManager) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            var targetInfo = stat()
            guard isContained(resolved, under: root),
                  lstat(resolved.path, &targetInfo) == 0,
                  (targetInfo.st_mode & S_IFMT) == S_IFREG || (targetInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
            return true
        }
        guard isImmutable(info) else { return false }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return (info.st_mode & S_IFMT) == S_IFREG
        }
        guard let entries = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) else {
            return false
        }
        return entries.allSatisfy { immutableTree($0, under: root, fileManager: fileManager) }
    }

    private static func collectRegularFiles(_ directory: URL, relativePrefix: String, root: URL, files: inout [(String, URL, String?)]) -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              isImmutable(info),
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else { return false }
        for entry in entries {
            var entryInfo = stat()
            guard lstat(entry.path, &entryInfo) == 0 else { return false }
            let relative = "\(relativePrefix)/\(entry.lastPathComponent)"
            guard entry.lastPathComponent.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return false }
            if (entryInfo.st_mode & S_IFMT) == S_IFLNK {
                guard let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path),
                      !linkTarget.isEmpty,
                      linkTarget.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return false }
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                var targetInfo = stat()
                guard isContained(resolved, under: root), lstat(resolved.path, &targetInfo) == 0,
                      (targetInfo.st_mode & S_IFMT) == S_IFREG || (targetInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
                files.append((relative, entry, linkTarget))
            } else if (entryInfo.st_mode & S_IFMT) == S_IFDIR {
                guard isImmutable(entryInfo), collectRegularFiles(entry, relativePrefix: relative, root: root, files: &files) else { return false }
            } else if (entryInfo.st_mode & S_IFMT) == S_IFREG {
                guard isImmutable(entryInfo) else { return false }
                files.append((relative, entry, nil))
            } else { return false }
        }
        return true
    }

    private static func isImmutable(_ info: stat) -> Bool {
        (info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) == 0
    }

    private static func usableFile(_ url: URL, minimumBytes: Int64, fileManager: FileManager) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, isImmutable(info) else { return false }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= minimumBytes else { return false }
        return true
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func containedURL(_ relativePath: String, under root: URL) -> URL? {
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false).resolvingSymlinksInPath().standardizedFileURL
        return isContained(candidate, under: root) ? candidate : nil
    }

    private static func containedRegularURL(_ relativePath: String, under root: URL, directory: Bool) -> URL? {
        let candidate = root.appendingPathComponent(relativePath, isDirectory: directory)
        var info = stat()
        guard lstat(candidate.path, &info) == 0,
              directory ? (info.st_mode & S_IFMT) == S_IFDIR : (info.st_mode & S_IFMT) == S_IFREG,
              isContained(candidate.resolvingSymlinksInPath().standardizedFileURL, under: root) else { return nil }
        return candidate
    }

    private static func isContained(_ candidate: URL, under root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
