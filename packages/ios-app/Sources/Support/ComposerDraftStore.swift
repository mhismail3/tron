import CryptoKit
import Foundation

enum ComposerDraftStorePolicy {
    static let version = 1
    /// Kept equal to ComposerDraftCoordinator.maxInactiveDrafts.
    static let maximumDraftCount = 24
    static let maximumTextBytes = 256 * 1_024
    static let maximumManifestBytes = 128 * 1_024
    static let maximumNameBytes = 512
    static let maximumMIMETypeBytes = 256
    static let maximumDiskBytes = 256 * 1_048_576
}

/// A bounded, local owner for unsent composer input. This store contains no
/// transcript, Gateway snapshot, credentials, upload identifiers, or source paths.
actor ComposerDraftStore {
    struct Attachment: Sendable, Equatable {
        let name: String
        let mimeType: String
        let data: Data
    }

    struct Value: Sendable, Equatable {
        let text: String
        let attachments: [Attachment]
    }

    private struct Manifest: Codable {
        let version: Int
        let updatedAt: UInt64
        let text: String
        let attachments: [AttachmentManifest]
    }

    private struct AttachmentManifest: Codable {
        let name: String
        let mimeType: String
        let size: Int
        let payload: String
    }

    private let root: URL
    private var logicalClock: UInt64 = 0
    #if HOSTED_TEST
    private let hostedBlocksLoads: Bool
    private var hostedLoadWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            self.root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appending(path: "ComposerDrafts", directoryHint: .isDirectory)
        }
        #if HOSTED_TEST
        hostedBlocksLoads = false
        #endif
    }

    #if HOSTED_TEST
    init(root: URL, hostedBlocksLoads: Bool) {
        self.root = root
        self.hostedBlocksLoads = hostedBlocksLoads
    }

    var hostedLoadWaiterCount: Int { hostedLoadWaiters.count }

    func hostedReleaseLoads() {
        let waiters = hostedLoadWaiters
        hostedLoadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    #endif

    func load(_ scope: ComposerDraftScope) async -> Value? {
        #if HOSTED_TEST
        if hostedBlocksLoads {
            await withCheckedContinuation { hostedLoadWaiters.append($0) }
        }
        #endif
        let directory = path(for: scope)
        do {
            try prepareRoot()
            _ = try validatedEntries(cleaningInvalid: true)
            let manifestURL = directory.appending(path: "manifest.json", directoryHint: .notDirectory)
            let manifestData = try readBounded(
                manifestURL,
                maximumBytes: ComposerDraftStorePolicy.maximumManifestBytes
            )
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.version == ComposerDraftStorePolicy.version,
                  manifest.updatedAt < UInt64.max,
                  manifest.text.utf8.count <= ComposerDraftStorePolicy.maximumTextBytes,
                  manifest.attachments.count <= ComposerAttachmentPolicy.maximumCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            logicalClock = max(logicalClock, manifest.updatedAt)
            var seenPayloads: Set<String> = []
            var totalBytes = 0
            var attachments: [Attachment] = []
            for (index, item) in manifest.attachments.enumerated() {
                guard item.size > 0,
                      item.size <= ComposerAttachmentPolicy.maximumTotalBytes,
                      item.name.utf8.count <= ComposerDraftStorePolicy.maximumNameBytes,
                      item.mimeType.utf8.count <= ComposerDraftStorePolicy.maximumMIMETypeBytes,
                      Self.isPayloadName(item.payload),
                      seenPayloads.insert(item.payload).inserted,
                      totalBytes <= ComposerAttachmentPolicy.maximumTotalBytes - item.size else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let payloadURL = directory.appending(path: item.payload, directoryHint: .notDirectory)
                let data = try readBounded(payloadURL, maximumBytes: item.size)
                let digestInput = Data("\(index)\u{0}".utf8) + data
                guard data.count == item.size,
                      item.payload == "\(Self.digest(digestInput)).payload" else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                totalBytes += data.count
                attachments.append(Attachment(name: item.name, mimeType: item.mimeType, data: data))
            }
            let expectedNames = seenPayloads.union(["manifest.json"])
            let actualNames = Set(try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ).map(\.lastPathComponent))
            guard actualNames == expectedNames else { throw CocoaError(.fileReadCorruptFile) }

            // A successful read is an LRU access, not a passive observation.
            // Advance the persisted logical clock before returning so restart
            // cannot forget that this scope was most recently used.
            logicalClock = try nextLogicalClock()
            let refreshedManifest = Manifest(
                version: manifest.version,
                updatedAt: logicalClock,
                text: manifest.text,
                attachments: manifest.attachments
            )
            let refreshedData = try JSONEncoder().encode(refreshedManifest)
            guard refreshedData.count <= ComposerDraftStorePolicy.maximumManifestBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try refreshedData.write(
                to: manifestURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return Value(text: manifest.text, attachments: attachments)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    func save(_ value: Value, for scope: ComposerDraftScope) {
        let directory = path(for: scope)
        guard Self.admits(value) else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let profileDirectory = directory.deletingLastPathComponent()
        let staging = profileDirectory.appending(
            path: ".staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try prepareRoot()
            logicalClock = try nextLogicalClock()
            try FileManager.default.createDirectory(
                at: profileDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [
                    .posixPermissions: 0o700,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            )
            var manifests: [AttachmentManifest] = []
            for (index, attachment) in value.attachments.enumerated() {
                let digestInput = Data("\(index)\u{0}".utf8) + attachment.data
                let payloadName = "\(Self.digest(digestInput)).payload"
                try attachment.data.write(
                    to: staging.appending(path: payloadName, directoryHint: .notDirectory),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                manifests.append(AttachmentManifest(
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    size: attachment.data.count,
                    payload: payloadName
                ))
            }
            let manifest = Manifest(
                version: ComposerDraftStorePolicy.version,
                updatedAt: logicalClock,
                text: value.text,
                attachments: manifests
            )
            let manifestData = try JSONEncoder().encode(manifest)
            guard manifestData.count <= ComposerDraftStorePolicy.maximumManifestBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try manifestData.write(
                to: staging.appending(path: "manifest.json", directoryHint: .notDirectory),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            if FileManager.default.fileExists(atPath: directory.path) {
                _ = try FileManager.default.replaceItemAt(
                    directory,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: staging, to: directory)
            }
            try enforceGlobalBounds(preserving: directory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            // The previous complete directory, if any, remains the last checkpoint.
        }
    }

    func remove(_ scope: ComposerDraftScope) {
        try? FileManager.default.removeItem(at: path(for: scope))
    }

    func removeProfile(_ profileID: String) {
        try? FileManager.default.removeItem(at: profilePath(profileID))
    }

    #if HOSTED_TEST
    func hostedPath(for scope: ComposerDraftScope) -> URL { path(for: scope) }
    #endif

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    private func profilePath(_ profileID: String) -> URL {
        root.appending(path: Self.digest(Data(profileID.utf8)), directoryHint: .isDirectory)
    }

    private func path(for scope: ComposerDraftScope) -> URL {
        profilePath(scope.profileID).appending(
            path: Self.digest(Data(scope.sessionID.utf8)),
            directoryHint: .isDirectory
        )
    }

    private func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    private func enforceGlobalBounds(preserving preserved: URL) throws {
        var entries = try validatedEntries(cleaningInvalid: true)
        entries.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.url.path < $1.url.path
        }
        var total = 0
        for entry in entries {
            let (next, overflow) = total.addingReportingOverflow(entry.bytes)
            total = overflow ? Int.max : next
        }
        while entries.count > ComposerDraftStorePolicy.maximumDraftCount
                || total > ComposerDraftStorePolicy.maximumDiskBytes {
            guard let index = entries.firstIndex(where: { $0.url != preserved }) else { break }
            let removed = entries.remove(at: index)
            total = max(0, total - removed.bytes)
            try? FileManager.default.removeItem(at: removed.url)
        }
    }

    private struct Entry {
        let url: URL
        let updatedAt: UInt64
        let bytes: Int
    }

    /// The persisted clock is recovered from every valid manifest so a new
    /// process cannot make a recently edited draft look older than prior data.
    private func nextLogicalClock() throws -> UInt64 {
        let latest = try validatedEntries(cleaningInvalid: true)
            .map(\.updatedAt)
            .max() ?? 0
        logicalClock = max(logicalClock, latest)
        guard logicalClock < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
        return logicalClock + 1
    }

    /// Validates the complete on-disk shape while collecting LRU accounting.
    /// Hidden crash-staging directories and every non-hash path are removed so
    /// neither corruption nor abandoned payloads can escape the global bound.
    private func validatedEntries(cleaningInvalid: Bool) throws -> [Entry] {
        let profileURLs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        var entries: [Entry] = []
        for profileURL in profileURLs {
            let profileValues = try? profileURL.resourceValues(forKeys: [.isDirectoryKey])
            guard profileValues?.isDirectory == true,
                  Self.isHashedComponent(profileURL.lastPathComponent) else {
                if cleaningInvalid { try? FileManager.default.removeItem(at: profileURL) }
                continue
            }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: profileURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true,
                      Self.isHashedComponent(url.lastPathComponent) else {
                    if cleaningInvalid { try? FileManager.default.removeItem(at: url) }
                    continue
                }
                do {
                    entries.append(try validatedEntry(at: url))
                } catch {
                    if cleaningInvalid { try? FileManager.default.removeItem(at: url) }
                }
            }
            if ((try? FileManager.default.contentsOfDirectory(atPath: profileURL.path)) ?? []).isEmpty {
                try? FileManager.default.removeItem(at: profileURL)
            }
        }
        return entries
    }

    private func validatedEntry(at directory: URL) throws -> Entry {
        let manifestData = try readBounded(
            directory.appending(path: "manifest.json", directoryHint: .notDirectory),
            maximumBytes: ComposerDraftStorePolicy.maximumManifestBytes
        )
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.version == ComposerDraftStorePolicy.version,
              manifest.updatedAt < UInt64.max,
              manifest.text.utf8.count <= ComposerDraftStorePolicy.maximumTextBytes,
              manifest.attachments.count <= ComposerAttachmentPolicy.maximumCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var expectedNames: Set<String> = ["manifest.json"]
        var bytes = manifestData.count
        for (index, item) in manifest.attachments.enumerated() {
            guard item.size > 0,
                  item.size <= ComposerAttachmentPolicy.maximumTotalBytes,
                  item.name.utf8.count <= ComposerDraftStorePolicy.maximumNameBytes,
                  item.mimeType.utf8.count <= ComposerDraftStorePolicy.maximumMIMETypeBytes,
                  Self.isPayloadName(item.payload),
                  expectedNames.insert(item.payload).inserted,
                  bytes <= ComposerAttachmentPolicy.maximumTotalBytes
                    + ComposerDraftStorePolicy.maximumManifestBytes - item.size else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let payloadURL = directory.appending(path: item.payload)
            let data = try readBounded(payloadURL, maximumBytes: item.size)
            let digestInput = Data("\(index)\u{0}".utf8) + data
            guard data.count == item.size,
                  item.payload == "\(Self.digest(digestInput)).payload" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            bytes += item.size
        }
        let actualNames = Set(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent))
        guard actualNames == expectedNames else { throw CocoaError(.fileReadCorruptFile) }
        return Entry(url: directory, updatedAt: manifest.updatedAt, bytes: bytes)
    }

    private static func admits(_ value: Value) -> Bool {
        guard !value.text.isEmpty || !value.attachments.isEmpty,
              value.text.utf8.count <= ComposerDraftStorePolicy.maximumTextBytes,
              value.attachments.count <= ComposerAttachmentPolicy.maximumCount else { return false }
        var total = 0
        for attachment in value.attachments {
            guard !attachment.data.isEmpty,
                  attachment.name.utf8.count <= ComposerDraftStorePolicy.maximumNameBytes,
                  attachment.mimeType.utf8.count <= ComposerDraftStorePolicy.maximumMIMETypeBytes,
                  total <= ComposerAttachmentPolicy.maximumTotalBytes - attachment.data.count else {
                return false
            }
            total += attachment.data.count
        }
        return true
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPayloadName(_ value: String) -> Bool {
        guard value.count == 72, value.hasSuffix(".payload") else { return false }
        return isHashedComponent(String(value.dropLast(8)))
    }

    private static func isHashedComponent(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
