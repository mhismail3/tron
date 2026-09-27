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

    private struct AttachmentManifest: Codable, Equatable {
        let name: String
        let mimeType: String
        let size: Int
        let payload: String
    }

    /// The attachments of the one directory this actor last wrote or fully
    /// verified, with the payload file identities it left there. A save whose
    /// attachments equal them, while every payload is still that exact file,
    /// replaces only the manifest. Holding one draft bounds the retained bytes
    /// to one attachment budget, usually shared with the composer's own copy.
    private struct PersistedAttachments {
        let scope: ComposerDraftScope
        let attachments: [Attachment]
        let manifests: [AttachmentManifest]
        let payloadIdentities: [PayloadIdentity]
    }

    /// Any rewrite, replacement or link swap of a payload changes one of these.
    private struct PayloadIdentity: Equatable {
        let fileNumber: UInt64
        let modificationDate: Date
        let size: UInt64
    }

    private let root: URL
    /// Recovered from every valid manifest at first use in this process, then
    /// advanced in memory: this actor is the only writer of `root`, so no other
    /// manifest can move ahead of it until the next process recovers again.
    private var logicalClock: UInt64 = 0
    private var hasRecoveredLogicalClock = false
    private var persistedAttachments: PersistedAttachments?
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
            absorbRecoveredClock(try validatedEntries(cleaningInvalid: true, verifyingPayloads: true))
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
            var payloadIdentities: [PayloadIdentity?] = []
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
                guard data.count == item.size,
                      item.payload == "\(Self.digest(prefix: Data("\(index)\u{0}".utf8), body: data)).payload" else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                totalBytes += data.count
                attachments.append(Attachment(name: item.name, mimeType: item.mimeType, data: data))
                payloadIdentities.append(Self.payloadIdentity(payloadURL))
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
            try replaceManifest(refreshedData, in: directory)
            rememberPersistedAttachments(
                attachments,
                manifests: manifest.attachments,
                payloadIdentities: payloadIdentities,
                for: scope
            )
            return Value(text: manifest.text, attachments: attachments)
        } catch {
            remove(scope)
            return nil
        }
    }

    func save(_ value: Value, for scope: ComposerDraftScope) {
        let directory = path(for: scope)
        guard Self.admits(value) else {
            remove(scope)
            return
        }
        let profileDirectory = directory.deletingLastPathComponent()
        let staging = profileDirectory.appending(
            path: ".staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try prepareRoot()
            if !hasRecoveredLogicalClock {
                absorbRecoveredClock(try validatedEntries(cleaningInvalid: true, verifyingPayloads: true))
            }
            logicalClock = try nextLogicalClock()
            if try !replaceManifestKeepingPayloads(value, scope: scope, directory: directory) {
                try writeDraftDirectory(value, scope: scope, directory: directory, staging: staging)
            }
            try enforceGlobalBounds(preserving: directory)
        } catch {
            if persistedAttachments?.scope == scope { persistedAttachments = nil }
            if ownsProfileDirectory(scope.profileID) {
                try? FileManager.default.removeItem(at: staging)
            }
            // The previous complete directory, if any, remains the last checkpoint.
        }
    }

    /// Writes every payload and the manifest into a fresh hidden staging
    /// directory, then swaps it in for the draft directory, so a crash leaves
    /// either the previous or the new complete directory plus abandoned
    /// staging that recovery and accounting remove.
    private func writeDraftDirectory(
        _ value: Value,
        scope: ComposerDraftScope,
        directory: URL,
        staging: URL
    ) throws {
        let profileDirectory = directory.deletingLastPathComponent()
        // A link or file where a directory belongs is removed as an entry,
        // never followed, before the replacement is created beside it.
        Self.removeNonDirectoryEntry(at: profileDirectory)
        try FileManager.default.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        Self.removeNonDirectoryEntry(at: directory)
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
            let payloadName = "\(Self.digest(prefix: Data("\(index)\u{0}".utf8), body: attachment.data)).payload"
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
        rememberPersistedAttachments(
            value.attachments,
            manifests: manifests,
            payloadIdentities: manifests.map {
                Self.payloadIdentity(directory.appending(path: $0.payload, directoryHint: .notDirectory))
            },
            for: scope
        )
    }

    private func rememberPersistedAttachments(
        _ attachments: [Attachment],
        manifests: [AttachmentManifest],
        payloadIdentities: [PayloadIdentity?],
        for scope: ComposerDraftScope
    ) {
        let identities = payloadIdentities.compactMap { $0 }
        persistedAttachments = identities.count == manifests.count
            ? PersistedAttachments(
                scope: scope,
                attachments: attachments,
                manifests: manifests,
                payloadIdentities: identities
            )
            : nil
    }

    /// Typing changes only the manifest. When `value` carries exactly the
    /// attachments this actor last wrote or verified for `scope`, and the draft
    /// directory still holds exactly those payload files, the new manifest
    /// replaces the old one in one rename and no payload is rewritten. Returns
    /// false, having touched nothing, whenever that cannot be shown.
    private func replaceManifestKeepingPayloads(
        _ value: Value,
        scope: ComposerDraftScope,
        directory: URL
    ) throws -> Bool {
        guard let persisted = persistedAttachments,
              persisted.scope == scope,
              persisted.attachments == value.attachments,
              ownsProfileDirectory(scope.profileID),
              Self.isOwnedDirectory(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              Set(names) == Set(persisted.manifests.map(\.payload)).union(["manifest.json"]),
              Self.isRegularFile(directory.appending(path: "manifest.json", directoryHint: .notDirectory)),
              persisted.manifests.indices.allSatisfy({ index in
                  Self.payloadIdentity(
                      directory.appending(path: persisted.manifests[index].payload, directoryHint: .notDirectory)
                  ) == persisted.payloadIdentities[index]
              }) else { return false }
        let manifestData = try JSONEncoder().encode(Manifest(
            version: ComposerDraftStorePolicy.version,
            updatedAt: logicalClock,
            text: value.text,
            attachments: persisted.manifests
        ))
        guard manifestData.count <= ComposerDraftStorePolicy.maximumManifestBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try replaceManifest(manifestData, in: directory)
        return true
    }

    /// Replaces `directory/manifest.json` with one rename(2). The new bytes are
    /// written beside the draft directories, never inside one: until the
    /// rename the draft still holds its previous complete manifest, and an
    /// interrupted write leaves only an unhashed profile-level file that
    /// recovery and accounting remove.
    private func replaceManifest(_ data: Data, in directory: URL) throws {
        let temporary = directory.deletingLastPathComponent().appending(
            path: ".manifest-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )
        do {
            try data.write(
                to: temporary,
                options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]
            )
            let destination = directory.appending(path: "manifest.json", directoryHint: .notDirectory)
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func remove(_ scope: ComposerDraftScope) {
        if persistedAttachments?.scope == scope { persistedAttachments = nil }
        guard ownsProfileDirectory(scope.profileID) else { return }
        try? FileManager.default.removeItem(at: path(for: scope))
    }

    func removeProfile(_ profileID: String) {
        if persistedAttachments?.scope.profileID == profileID { persistedAttachments = nil }
        guard Self.isOwnedDirectory(root) else { return }
        try? FileManager.default.removeItem(at: profilePath(profileID))
    }

    private func ownsProfileDirectory(_ profileID: String) -> Bool {
        Self.isOwnedDirectory(root) && Self.isOwnedDirectory(profilePath(profileID))
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        // Inspect the directory entry itself, without cached URL resource values
        // or following a link into another in-sandbox owner during cleanup.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    private static func removeNonDirectoryEntry(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType != .typeDirectory else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func payloadIdentity(_ url: URL) -> PayloadIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }
        return PayloadIdentity(fileNumber: fileNumber, modificationDate: modificationDate, size: size)
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
        guard Self.isOwnedDirectory(root) else { throw CocoaError(.fileReadCorruptFile) }
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

    /// Accounting reads manifests and payload file sizes only. Payload digests
    /// are verified at first use in each process and by `load` before any
    /// restore; every structural fault is still removed here.
    private func enforceGlobalBounds(preserving preserved: URL) throws {
        var entries = try validatedEntries(cleaningInvalid: true, verifyingPayloads: false)
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
            if let persisted = persistedAttachments, path(for: persisted.scope) == removed.url {
                persistedAttachments = nil
            }
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
    private func absorbRecoveredClock(_ entries: [Entry]) {
        logicalClock = max(logicalClock, entries.map(\.updatedAt).max() ?? 0)
        hasRecoveredLogicalClock = true
    }

    private func nextLogicalClock() throws -> UInt64 {
        guard logicalClock < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
        return logicalClock + 1
    }

    /// Validates the complete on-disk shape while collecting LRU accounting.
    /// Hidden crash-staging directories and every non-hash path are removed so
    /// neither corruption nor abandoned payloads can escape the global bound.
    private func validatedEntries(cleaningInvalid: Bool, verifyingPayloads: Bool) throws -> [Entry] {
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
                    entries.append(try validatedEntry(at: url, verifyingPayloads: verifyingPayloads))
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

    private func validatedEntry(at directory: URL, verifyingPayloads: Bool) throws -> Entry {
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
            if verifyingPayloads {
                let data = try readBounded(payloadURL, maximumBytes: item.size)
                guard data.count == item.size,
                      item.payload == "\(Self.digest(prefix: Data("\(index)\u{0}".utf8), body: data)).payload" else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } else {
                let values = try payloadURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.fileSize == item.size else {
                    throw CocoaError(.fileReadCorruptFile)
                }
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

    /// Hash the exact logical prefix and payload without allocating their
    /// concatenation. The prefix is intentionally still included in every
    /// attachment digest so duplicate bytes at different indexes retain
    /// distinct, restart-stable filenames.
    private static func digest(prefix: Data, body: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: prefix)
        hasher.update(data: body)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isPayloadName(_ value: String) -> Bool {
        guard value.count == 72, value.hasSuffix(".payload") else { return false }
        return isHashedComponent(String(value.dropLast(8)))
    }

    private static func isHashedComponent(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
