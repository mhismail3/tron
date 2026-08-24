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

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "composer-draft-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
