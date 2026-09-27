import CryptoKit
import Foundation
import Testing
@testable import TronMobile

@Suite("Composer draft store", .serialized)
struct ComposerDraftStoreTests {
    @Test("text, photo, and file bytes round trip through hashed separate payload paths")
    func roundTripAndHashedPaths() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let scope = ComposerDraftScope(
            profileID: "profile-sensitive-identifier",
            sessionID: "session-sensitive-identifier"
        )
        let value = ComposerDraftStore.Value(
            text: "restart me",
            attachments: [
                .init(name: "photo.jpg", mimeType: "image/jpeg", data: Data([0xff, 0xd8, 1, 2])),
                .init(name: "notes.txt", mimeType: "text/plain", data: Data("exact file".utf8)),
            ]
        )

        await store.save(value, for: scope)

        #expect(await store.load(scope) == value)
        let directory = await store.hostedPath(for: scope)
        #expect(!directory.path.contains(scope.profileID))
        #expect(!directory.path.contains(scope.sessionID))
        #expect(directory.lastPathComponent.count == 64)
        #expect(directory.deletingLastPathComponent().lastPathComponent.count == 64)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains("manifest.json"))
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(names.filter { $0.hasSuffix(".payload") }.count == 2)
        let manifest = try Data(contentsOf: directory.appending(path: "manifest.json"))
        #expect(!String(decoding: manifest, as: UTF8.self).contains("exact file"))

        let replacement = ComposerDraftStore.Value(text: "newer", attachments: [value.attachments[1]])
        await store.save(replacement, for: scope)
        #expect(await store.load(scope) == replacement)
    }

    @Test("malformed and oversized values fail closed and clean their scope")
    func corruptionAndBounds() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let scope = ComposerDraftScope(profileID: "profile", sessionID: "session")
        await store.save(.init(text: "safe", attachments: []), for: scope)
        let directory = await store.hostedPath(for: scope)
        try Data("not-json".utf8).write(
            to: directory.appending(path: "manifest.json"),
            options: .atomic
        )

        #expect(await store.load(scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        await store.save(.init(text: "safe", attachments: []), for: scope)
        try Data("hidden-corruption".utf8).write(
            to: directory.appending(path: ".abandoned-payload")
        )
        #expect(await store.load(scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        await store.save(.init(
            text: String(repeating: "x", count: ComposerDraftStorePolicy.maximumTextBytes + 1),
            attachments: []
        ), for: scope)
        #expect(await store.load(scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("draft count is restart-stable LRU bounded and profile removal crosses restart")
    func LRUAndProfileRemoval() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store = ComposerDraftStore(root: root)
        for index in 0 ..< ComposerDraftStorePolicy.maximumDraftCount {
            await store.save(
                .init(text: "draft-\(index)", attachments: []),
                for: .init(profileID: "profile", sessionID: "session-\(index)")
            )
        }

        // A fresh actor must recover the persisted logical clock. Successfully
        // loading the oldest draft makes it newest before the extra save evicts
        // session-1, including across this actor restart.
        store = ComposerDraftStore(root: root)
        let sessionZero = ComposerDraftScope(profileID: "profile", sessionID: "session-0")
        #expect(await store.load(sessionZero)?.text == "draft-0")
        let newest = ComposerDraftScope(profileID: "profile", sessionID: "session-new")
        await store.save(.init(text: "new", attachments: []), for: newest)

        #expect(await store.load(sessionZero)?.text == "draft-0")
        #expect(await store.load(.init(profileID: "profile", sessionID: "session-1")) == nil)
        #expect(await store.load(newest)?.text == "new")

        await store.removeProfile("profile")
        #expect(await store.load(newest) == nil)
    }

    @Test("typing saves keep the exact payload files and restore after restart")
    func unchangedAttachmentsKeepPayloadFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let scope = ComposerDraftScope(profileID: "profile", sessionID: "typing")
        let attachments: [ComposerDraftStore.Attachment] = [
            .init(name: "photo.jpg", mimeType: "image/jpeg", data: Data(repeating: 7, count: 300_000)),
            .init(name: "notes.txt", mimeType: "text/plain", data: Data("exact file".utf8)),
        ]
        await store.save(.init(text: "h", attachments: attachments), for: scope)
        let directory = await store.hostedPath(for: scope)
        let written = try payloadIdentities(in: directory)
        #expect(written.count == 2)

        for text in ["he", "hel", "hello"] {
            await store.save(.init(text: text, attachments: attachments), for: scope)
        }
        #expect(try payloadIdentities(in: directory) == written)
        #expect(try siblingNames(of: directory).isEmpty)

        let restarted = ComposerDraftStore(root: root)
        #expect(await restarted.load(scope) == .init(text: "hello", attachments: attachments))

        // A payload replaced underneath the store is rewritten from memory
        // rather than trusted.
        let loadedIdentities = try payloadIdentities(in: directory)
        let payload = try #require(loadedIdentities.keys.first)
        try Data(repeating: 9, count: 10).write(to: directory.appending(path: payload), options: .atomic)
        await restarted.save(.init(text: "hello!", attachments: attachments), for: scope)
        #expect(await ComposerDraftStore(root: root).load(scope) == .init(text: "hello!", attachments: attachments))
    }

    @Test("a draft interrupted at any save step restores the previous complete draft")
    func interruptedSavesKeepPreviousDraft() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ComposerDraftScope(profileID: "profile", sessionID: "crash")
        let previous = ComposerDraftStore.Value(
            text: "previous",
            attachments: [.init(name: "notes.txt", mimeType: "text/plain", data: Data("bytes".utf8))]
        )
        await ComposerDraftStore(root: root).save(previous, for: scope)
        let directory = await ComposerDraftStore(root: root).hostedPath(for: scope)
        let profileDirectory = directory.deletingLastPathComponent()

        // The only on-disk states a crash can leave besides a complete draft:
        // a partly written manifest replacement beside the draft, and a partly
        // written staging directory for a changed attachment set.
        try Data(#"{"version":1,"updatedAt":9"#.utf8)
            .write(to: profileDirectory.appending(path: ".manifest-\(UUID().uuidString)"))
        let staging = profileDirectory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: staging.appending(path: "manifest.json"))

        let restarted = ComposerDraftStore(root: root)
        #expect(await restarted.load(scope) == previous)
        #expect(try siblingNames(of: directory).isEmpty)

        // The same leftovers found by a first save instead of a load are
        // removed too, and the new draft becomes the complete one.
        try Data("torn".utf8).write(to: profileDirectory.appending(path: ".manifest-\(UUID().uuidString)"))
        let next = ComposerDraftStore.Value(text: "next", attachments: previous.attachments)
        let afterRestart = ComposerDraftStore(root: root)
        await afterRestart.save(next, for: scope)
        #expect(try siblingNames(of: directory).isEmpty)
        #expect(await ComposerDraftStore(root: root).load(scope) == next)
    }

    @Test("typing saves advance LRU order and the global count bound still evicts")
    func manifestOnlySavesKeepLRUBounds() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let attachment = ComposerDraftStore.Attachment(
            name: "notes.txt", mimeType: "text/plain", data: Data("attached".utf8)
        )
        let scopes = (0 ..< ComposerDraftStorePolicy.maximumDraftCount).map {
            ComposerDraftScope(profileID: "profile", sessionID: "session-\($0)")
        }
        for (index, scope) in scopes.enumerated() {
            await store.save(.init(text: "draft-\(index)", attachments: [attachment]), for: scope)
        }
        // Typing in the oldest draft: one full write, then manifest-only
        // writes, each its latest use.
        for text in ["draft-0 e", "draft-0 ed", "draft-0 edited"] {
            await store.save(.init(text: text, attachments: [attachment]), for: scopes[0])
        }
        let newest = ComposerDraftScope(profileID: "profile", sessionID: "session-new")
        await store.save(.init(text: "new", attachments: [attachment]), for: newest)
        let profileDirectory = (await store.hostedPath(for: newest)).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: profileDirectory.path).count
            == ComposerDraftStorePolicy.maximumDraftCount)

        // The order persisted by the manifest-only writes survives a restart:
        // the next eviction still takes the next-oldest draft.
        let restarted = ComposerDraftStore(root: root)
        let later = ComposerDraftScope(profileID: "profile", sessionID: "session-later")
        await restarted.save(.init(text: "later", attachments: [attachment]), for: later)
        #expect(try FileManager.default.contentsOfDirectory(atPath: profileDirectory.path).count
            == ComposerDraftStorePolicy.maximumDraftCount)
        #expect(await restarted.load(scopes[1]) == nil)
        #expect(await restarted.load(scopes[2]) == nil)
        #expect(await restarted.load(scopes[0])?.text == "draft-0 edited")
        #expect(await restarted.load(scopes[3])?.text == "draft-3")
        #expect(await restarted.load(newest)?.text == "new")
        #expect(await restarted.load(later)?.text == "later")
    }

    @Test("load still discards same-size corruption that keeps the payload file identity")
    func loadVerifiesPayloadsAfterTypingSaves() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let scope = ComposerDraftScope(profileID: "profile", sessionID: "silent")
        let attachments: [ComposerDraftStore.Attachment] = [
            .init(name: "notes.txt", mimeType: "text/plain", data: Data("original".utf8)),
        ]
        await store.save(.init(text: "a", attachments: attachments), for: scope)
        let directory = await store.hostedPath(for: scope)
        let payload = try #require(try payloadIdentities(in: directory).keys.first)
        let payloadURL = directory.appending(path: payload)
        var original = stat()
        #expect(lstat(payloadURL.path, &original) == 0)
        // Overwrite in place and restore the exact timestamps: the typing save
        // cannot tell, so only load's digest verification stands between these
        // bytes and a restored draft.
        let handle = try FileHandle(forWritingTo: payloadURL)
        try handle.write(contentsOf: Data("mutated!".utf8))
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, payloadURL.path, &times, 0) == 0)
        await store.save(.init(text: "ab", attachments: attachments), for: scope)
        #expect(String(decoding: try Data(contentsOf: payloadURL), as: UTF8.self) == "mutated!")

        #expect(await store.load(scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("attachment filenames hash exact prefix and body bytes")
    func attachmentDigestDifferential() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let scope = ComposerDraftScope(profileID: "profile", sessionID: "unicode-\u{1F30D}")
        let bytes = Data((String(repeating: "é", count: 150_000) + "\u{1F642}").utf8)
        await store.save(.init(text: "large", attachments: [
            .init(name: "one", mimeType: "application/octet-stream", data: bytes),
            .init(name: "two", mimeType: "application/octet-stream", data: bytes),
        ]), for: scope)

        let directory = await store.hostedPath(for: scope)
        let manifest = try JSONDecoder().decode(AttachmentManifestFixture.self, from: Data(
            contentsOf: directory.appending(path: "manifest.json")
        ))
        #expect(manifest.attachments.map(\.payload) == [
            "\(expectedDigest(index: 0, body: bytes)).payload",
            "\(expectedDigest(index: 1, body: bytes)).payload",
        ])
        #expect(manifest.attachments[0].payload != manifest.attachments[1].payload)
        #expect(await store.load(scope)?.attachments.map(\.data) == [bytes, bytes])
    }

    @Test("payload digest rejects same-size corruption")
    func sameSizePayloadCorruption() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let scope = ComposerDraftScope(profileID: "profile", sessionID: "corrupt")
        await store.save(.init(
            text: "safe",
            attachments: [.init(
                name: "notes.txt",
                mimeType: "text/plain",
                data: Data("original".utf8)
            )]
        ), for: scope)
        let directory = await store.hostedPath(for: scope)
        let payload = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path)
            .first(where: { $0.hasSuffix(".payload") }))
        try Data("mutated!".utf8).write(to: directory.appending(path: payload), options: .atomic)

        #expect(await store.load(scope) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("maximum timestamp is rejected and cannot poison later saves")
    func maximumTimestampFailsClosed() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(root: root)
        let poisoned = ComposerDraftScope(profileID: "profile", sessionID: "poisoned")
        await store.save(.init(text: "old", attachments: []), for: poisoned)
        let directory = await store.hostedPath(for: poisoned)
        let manifestURL = directory.appending(path: "manifest.json")
        let manifest = String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
        let expression = try NSRegularExpression(pattern: #"\"updatedAt\":\d+"#)
        let range = NSRange(manifest.startIndex..<manifest.endIndex, in: manifest)
        let poisonedManifest = expression.stringByReplacingMatches(
            in: manifest,
            range: range,
            withTemplate: #"\"updatedAt\":18446744073709551615"#
        )
        try Data(poisonedManifest.utf8).write(to: manifestURL, options: .atomic)

        #expect(await store.load(poisoned) == nil)
        let healthy = ComposerDraftScope(profileID: "profile", sessionID: "healthy")
        await store.save(.init(text: "new", attachments: []), for: healthy)
        #expect(await store.load(healthy)?.text == "new")
    }

    enum LinkBoundary: CaseIterable, Sendable {
        case root, profile, session, manifest, payload
    }

    enum StoreOperation: CaseIterable, Sendable {
        case load, save, saveEmpty, remove, removeProfile
    }

    @Test("draft operations reject linked loads and preserve target bytes",
          arguments: LinkBoundary.allCases, StoreOperation.allCases)
    func symbolicLinks(boundary: LinkBoundary, operation: StoreOperation) async throws {
        let parent = temporaryRoot()
        let outside = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        let root = parent.appending(path: "drafts", directoryHint: .isDirectory)
        let store = ComposerDraftStore(root: root)
        let scope = ComposerDraftScope(profileID: "profile", sessionID: "session")
        let original = ComposerDraftStore.Value(
            text: "retained draft",
            attachments: [.init(name: "notes.txt", mimeType: "text/plain", data: Data("exact bytes".utf8))]
        )
        await store.save(original, for: scope)
        #expect(await store.load(scope) == original)
        let directory = await store.hostedPath(for: scope)
        let link: URL
        switch boundary {
        case .root: link = root
        case .profile: link = directory.deletingLastPathComponent()
        case .session: link = directory
        case .manifest: link = directory.appending(path: "manifest.json")
        case .payload:
            let name = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".payload") }))
            link = directory.appending(path: name)
        }
        let isDirectory = try link.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appending(path: "target")
        try FileManager.default.moveItem(at: link, to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        if isDirectory {
            try Data("outside sentinel".utf8).write(to: target.appending(path: "sentinel"))
        }
        let before = try fileBytes(in: outside)

        switch operation {
        case .load: #expect(await store.load(scope) == nil)
        case .save: await store.save(.init(text: "new draft", attachments: []), for: scope)
        case .saveEmpty: await store.save(.init(text: "", attachments: []), for: scope)
        case .remove: await store.remove(scope)
        case .removeProfile: await store.removeProfile(scope.profileID)
        }
        #expect(try fileBytes(in: outside) == before)
    }

    private func fileBytes(in root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return files
    }

    /// Payload file name to (inode, modification date): a rewrite changes it.
    private func payloadIdentities(in directory: URL) throws -> [String: String] {
        var identities: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".payload") {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            identities[name] = "\(inode)-\(modified)"
        }
        return identities
    }

    /// Entries beside the draft directories in its profile directory.
    private func siblingNames(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path)
            .filter { $0 != directory.lastPathComponent }
    }

    private struct AttachmentManifestFixture: Decodable {
        let attachments: [AttachmentFixture]
    }

    private struct AttachmentFixture: Decodable {
        let payload: String
    }

    private func expectedDigest(index: Int, body: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(index)\u{0}".utf8))
        hasher.update(data: body)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "composer-draft-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
