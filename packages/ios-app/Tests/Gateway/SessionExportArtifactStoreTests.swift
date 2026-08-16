import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded session export artifacts")
struct SessionExportArtifactStoreTests {
    @Test("gateway filenames cannot escape the owned export directory")
    func safeNames() {
        #expect(SessionExportArtifactStore.safeFilename("../../secret.jsonl") == "secret.jsonl")
        #expect(SessionExportArtifactStore.safeFilename("/private/report.html") == "report.html")
        #expect(SessionExportArtifactStore.safeFilename("..") == "export")
        #expect(SessionExportArtifactStore.safeFilename("/") == "export")
        #expect(SessionExportArtifactStore.safeFilename("////") == "export")
        #expect(SessionExportArtifactStore.safeFilename("\u{0}\n") == "export")
        let long = SessionExportArtifactStore.safeFilename(String(repeating: "é", count: 200))
        #expect(long.utf8.count <= SessionExportArtifactPolicy.maximumFilenameBytes)
    }

    @Test("artifacts are unique, byte bounded, protected, and backup excluded")
    func writePolicy() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identifiers = UUIDSequence([
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        ])
        let store = SessionExportArtifactStore(
            root: root,
            maximumBytes: 8,
            uuid: identifiers.next
        )

        let first = try await store.write(Data(repeating: 1, count: 8), suggestedName: "../report.html")
        let second = try await store.write(Data([2]), suggestedName: "report.html")
        #expect(first.lastPathComponent == "report.html")
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
        #expect(first.deletingLastPathComponent().deletingLastPathComponent() == root)
        #expect((try root.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true)
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: first.path)
        if let protection = rootAttributes[.protectionKey] as? FileProtectionType {
            #expect(protection == .complete)
        }
        if let protection = folderAttributes[.protectionKey] as? FileProtectionType {
            #expect(protection == .complete)
        }
        if let protection = fileAttributes[.protectionKey] as? FileProtectionType {
            #expect(protection == .complete)
        }
        #if !targetEnvironment(simulator)
        #expect(rootAttributes[.protectionKey] as? FileProtectionType == .complete)
        #expect(folderAttributes[.protectionKey] as? FileProtectionType == .complete)
        #expect(fileAttributes[.protectionKey] as? FileProtectionType == .complete)
        #endif
        #expect(try Data(contentsOf: first).count == 8)
        await #expect(throws: URLError.self) {
            try await store.write(Data(repeating: 3, count: 9), suggestedName: "large.jsonl")
        }
    }

    @Test("pruning and discard remove only owned artifacts")
    func cleanup() async throws {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let now = Date(timeIntervalSince1970: 20_000)
        let store = SessionExportArtifactStore(
            root: root,
            maximumBytes: 8,
            maximumAge: 100,
            now: { now }
        )
        let artifact = try await store.write(Data([1]), suggestedName: "current.jsonl")
        let old = root.appending(path: "old", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-101)],
            ofItemAtPath: old.path
        )
        let malformed = root.appending(path: "loose-file")
        try Data([2]).write(to: malformed)

        try await store.prune()
        #expect(FileManager.default.fileExists(atPath: artifact.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: malformed.path))

        await store.discard(artifact)
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appending(path: "keep")
        try Data([3]).write(to: outsideFile)
        await store.discard(outsideFile)
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "SessionExportArtifactStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) { self.values = values }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}
