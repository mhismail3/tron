import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded session export artifacts")
struct SessionExportArtifactStoreTests {
    @Test("versioned and legacy responses enforce their independent exact-size contracts")
    func downloadAdmission() throws {
        let versioned = try SessionExportDownloadAdmission.resolve(
            supportsLargeExports: true,
            declaredBytes: Int64(SessionExportArtifactPolicy.legacyMaximumEncodedBytes) + 1
        )
        #expect(versioned.maximumBytes == SessionExportArtifactPolicy.legacyMaximumEncodedBytes + 1)
        #expect(versioned.expectedBytes == Int64(versioned.maximumBytes))
        #expect(throws: SessionExportDownloadAdmissionError.self) {
            _ = try SessionExportDownloadAdmission.resolve(
                supportsLargeExports: true,
                declaredBytes: nil
            )
        }
        #expect(throws: SessionExportDownloadAdmissionError.self) {
            _ = try SessionExportDownloadAdmission.resolve(
                supportsLargeExports: true,
                declaredBytes: 0
            )
        }
        #expect(throws: SessionExportDownloadAdmissionError.self) {
            _ = try SessionExportDownloadAdmission.resolve(
                supportsLargeExports: true,
                declaredBytes: Int64(SessionExportArtifactPolicy.maximumEncodedBytes) + 1
            )
        }

        let legacy = try SessionExportDownloadAdmission.resolve(
            supportsLargeExports: false,
            declaredBytes: nil
        )
        #expect(legacy.maximumBytes == SessionExportArtifactPolicy.legacyMaximumEncodedBytes)
        #expect(legacy.reservedBytes == Int64(SessionExportArtifactPolicy.legacyMaximumEncodedBytes))
        #expect(legacy.expectedBytes == nil)
        #expect(throws: SessionExportDownloadAdmissionError.self) {
            _ = try SessionExportDownloadAdmission.resolve(
                supportsLargeExports: false,
                declaredBytes: 0
            )
        }
        #expect(throws: SessionExportDownloadAdmissionError.self) {
            _ = try SessionExportDownloadAdmission.resolve(
                supportsLargeExports: false,
                declaredBytes: Int64(SessionExportArtifactPolicy.legacyMaximumEncodedBytes) + 1
            )
        }
    }

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
    func adoptionOwnership() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionExportArtifactStore(root: root, maximumBytes: 8)

        let first = try await adoptFixture(Data(repeating: 1, count: 8), into: store, suggestedName: "../report.html")
        let second = try await adoptFixture(Data([2]), into: store, suggestedName: "report.html")
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
            try await adoptFixture(Data(repeating: 3, count: 9), into: store, suggestedName: "large.jsonl")
        }
    }

    @Test("staged files move into protected ownership without data buffering")
    func adoptPolicy() async throws {
        let root = temporaryRoot()
        let staging = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = staging.appending(path: "download")
        try Data(repeating: 7, count: 8).write(to: source)
        let store = SessionExportArtifactStore(root: root, maximumBytes: 8)

        let reservation = try await store.prepareDownload(expectedBytes: 8)
        let artifact = try await store.adopt(source, suggestedName: "../session.jsonl", reservation: reservation)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(artifact.lastPathComponent == "session.jsonl")
        #expect(try Data(contentsOf: artifact) == Data(repeating: 7, count: 8))

        let oversized = staging.appending(path: "oversized")
        let oversizedReservation = try await store.prepareDownload(expectedBytes: 8)
        try Data(repeating: 8, count: 9).write(to: oversized)
        await #expect(throws: URLError.self) {
            try await store.adopt(oversized, suggestedName: "large.jsonl", reservation: oversizedReservation)
        }
        await store.cancelDownload(oversizedReservation)
        #expect(FileManager.default.fileExists(atPath: oversized.path))
    }

    @Test("artifact ownership rejects a symbolic-link root")
    func symbolicLinkRoot() async throws {
        let parent = temporaryRoot()
        let outside = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let root = parent.appending(path: "exports")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let store = SessionExportArtifactStore(root: root, maximumBytes: 8)
        await #expect(throws: URLError.self) {
            try await adoptFixture(Data([1]), into: store, suggestedName: "blocked.jsonl")
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    @Test("download reservations hold aggregate and item capacity until adoption or cancellation")
    func downloadReservations() async throws {
        let root = temporaryRoot()
        let staging = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let store = SessionExportArtifactStore(
            root: root,
            maximumBytes: 8,
            maximumTotalBytes: 10,
            maximumArtifacts: 1
        )
        let reservation = try await store.prepareDownload(expectedBytes: 6)
        await #expect(throws: URLError.self) {
            _ = try await store.prepareDownload(expectedBytes: 5)
        }

        let source = staging.appending(path: "download")
        try Data(repeating: 7, count: 6).write(to: source)
        let artifact = try await store.adopt(
            source,
            suggestedName: "reserved.jsonl",
            reservation: reservation
        )
        #expect(try Data(contentsOf: artifact).count == 6)
        await store.discard(artifact)

        let cancelled = try await store.prepareDownload(expectedBytes: 8)
        await store.cancelDownload(cancelled)
        try Data([1]).write(to: source)
        for retired in [reservation, cancelled] {
            await #expect(throws: URLError.self) {
                try await store.adopt(source, suggestedName: "retired.jsonl", reservation: retired)
            }
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
        let replacement = try await adoptFixture(Data([1]), into: store, suggestedName: "replacement.jsonl")
        #expect(FileManager.default.fileExists(atPath: replacement.path))
    }

    @Test("active artifacts enforce aggregate and count capacity without unsafe eviction")
    func activeCapacity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionExportArtifactStore(
            root: root,
            maximumBytes: 8,
            maximumTotalBytes: 10,
            maximumArtifacts: 1
        )
        let first = try await adoptFixture(Data(repeating: 1, count: 6), into: store, suggestedName: "first.jsonl")
        await #expect(throws: URLError.self) {
            try await adoptFixture(Data(repeating: 2, count: 5), into: store, suggestedName: "second.jsonl")
        }
        #expect(FileManager.default.fileExists(atPath: first.path))

        await store.discard(first)
        let replacement = try await adoptFixture(Data(repeating: 3, count: 5), into: store, suggestedName: "replacement.jsonl")
        #expect(try Data(contentsOf: replacement).count == 5)
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
        let artifact = try await adoptFixture(Data([1]), into: store, suggestedName: "current.jsonl")
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

    /// Only fixture bytes are buffered. Exercise the same reservation and
    /// file-adoption boundary as AppModel's actual export download.
    private func adoptFixture(
        _ data: Data,
        into store: SessionExportArtifactStore,
        suggestedName: String
    ) async throws -> URL {
        let staging = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = staging.appending(path: "download")
        try data.write(to: source)
        let reservation = try await store.prepareDownload(expectedBytes: Int64(data.count))
        do {
            return try await store.adopt(source, suggestedName: suggestedName, reservation: reservation)
        } catch {
            await store.cancelDownload(reservation)
            throw error
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "SessionExportArtifactStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}
