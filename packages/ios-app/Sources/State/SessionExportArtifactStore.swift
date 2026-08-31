import Foundation

enum SessionExportArtifactPolicy {
    // Session exports are disk-backed archival artifacts, not media blobs. Keep
    // their capacity policy independent from the 25 MiB attachment/image bound.
    static let maximumEncodedBytes = 2 * 1_024 * 1_024 * 1_024
    static let legacyMaximumEncodedBytes = 25 * 1_048_576
    static let maximumTotalBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumArtifacts = 8
    static let minimumFreeBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumFilenameBytes = 160
    static let maximumAge: TimeInterval = 24 * 60 * 60
}

enum SessionExportDownloadAdmissionError: Error {
    case invalidVersionedSize
    case legacySizeExceeded
}

struct SessionExportDownloadAdmission: Equatable {
    let maximumBytes: Int
    let reservedBytes: Int64
    let expectedBytes: Int64?

    static func resolve(
        supportsLargeExports: Bool,
        declaredBytes: Int64?
    ) throws -> SessionExportDownloadAdmission {
        if supportsLargeExports {
            guard let declaredBytes,
                  declaredBytes > 0,
                  declaredBytes <= Int64(SessionExportArtifactPolicy.maximumEncodedBytes),
                  let maximumBytes = Int(exactly: declaredBytes) else {
                throw SessionExportDownloadAdmissionError.invalidVersionedSize
            }
            return SessionExportDownloadAdmission(
                maximumBytes: maximumBytes,
                reservedBytes: declaredBytes,
                expectedBytes: declaredBytes
            )
        }
        if let declaredBytes,
           (declaredBytes <= 0
            || declaredBytes > Int64(SessionExportArtifactPolicy.legacyMaximumEncodedBytes)) {
            throw SessionExportDownloadAdmissionError.legacySizeExceeded
        }
        return SessionExportDownloadAdmission(
            maximumBytes: SessionExportArtifactPolicy.legacyMaximumEncodedBytes,
            reservedBytes: declaredBytes
                ?? Int64(SessionExportArtifactPolicy.legacyMaximumEncodedBytes),
            expectedBytes: declaredBytes
        )
    }
}

struct SessionExportArtifactReservation: Sendable {
    fileprivate let id: UUID
    fileprivate let maximumBytes: Int64
}

actor SessionExportArtifactStore {
    private let root: URL
    private let maximumBytes: Int
    private let maximumTotalBytes: Int64
    private let maximumArtifacts: Int
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID
    private var activeArtifacts: Set<URL> = []
    private var reservations: [UUID: Int64] = [:]

    init(
        root: URL = FileManager.default.temporaryDirectory.appending(
            path: "TronExports",
            directoryHint: .isDirectory
        ),
        maximumBytes: Int = SessionExportArtifactPolicy.maximumEncodedBytes,
        maximumTotalBytes: Int64 = SessionExportArtifactPolicy.maximumTotalBytes,
        maximumArtifacts: Int = SessionExportArtifactPolicy.maximumArtifacts,
        maximumAge: TimeInterval = SessionExportArtifactPolicy.maximumAge,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        precondition(maximumBytes >= 0)
        precondition(maximumTotalBytes >= Int64(maximumBytes))
        precondition(maximumArtifacts > 0)
        precondition(maximumAge >= 0)
        self.root = root
        self.maximumBytes = maximumBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumArtifacts = maximumArtifacts
        self.maximumAge = maximumAge
        self.now = now
        self.uuid = uuid
    }

    func prepareDownload(expectedBytes: Int64) throws -> SessionExportArtifactReservation {
        try prepareForIncoming(byteCount: expectedBytes, additionalDiskBytes: expectedBytes)
        let reservation = SessionExportArtifactReservation(id: UUID(), maximumBytes: expectedBytes)
        reservations[reservation.id] = expectedBytes
        return reservation
    }

    func cancelDownload(_ reservation: SessionExportArtifactReservation) {
        reservations.removeValue(forKey: reservation.id)
    }

    func write(_ data: Data, suggestedName: String) throws -> URL {
        guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        try prepareForIncoming(byteCount: Int64(data.count), additionalDiskBytes: Int64(data.count))
        let folder = root.appending(path: uuid().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            let destination = folder.appending(
                path: Self.safeFilename(suggestedName),
                directoryHint: .notDirectory
            )
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            activeArtifacts.insert(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func adopt(
        _ source: URL,
        suggestedName: String,
        reservation: SessionExportArtifactReservation? = nil
    ) throws -> URL {
        let values = try source.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        if let reservation {
            guard reservations.removeValue(forKey: reservation.id) != nil,
                  Int64(fileSize) <= reservation.maximumBytes else {
                throw URLError(.cannotCreateFile)
            }
        }
        try prepareForIncoming(byteCount: Int64(fileSize), additionalDiskBytes: 0)
        let folder = root.appending(path: uuid().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            let destination = folder.appending(
                path: Self.safeFilename(suggestedName),
                directoryHint: .notDirectory
            )
            try FileManager.default.moveItem(at: source, to: destination)
            let admitted = try destination.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard admitted.isRegularFile == true,
                  admitted.isSymbolicLink != true,
                  admitted.fileSize == fileSize else {
                throw URLError(.cannotDecodeContentData)
            }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: destination.path
            )
            activeArtifacts.insert(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func discard(_ artifact: URL) {
        guard activeArtifacts.remove(artifact) != nil else { return }
        let folder = artifact.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func prune() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let cutoff = now().addingTimeInterval(-maximumAge)
        var records = try artifactRecords(removingMalformed: true).filter { record in
            guard record.modified >= cutoff else {
                if !record.active { try? FileManager.default.removeItem(at: record.folder) }
                return record.active
            }
            return true
        }
        var total = try Self.checkedTotal(records.map(\.size))
        while records.count > maximumArtifacts || total > maximumTotalBytes {
            guard let index = records.firstIndex(where: { !$0.active }) else { break }
            let record = records.remove(at: index)
            try? FileManager.default.removeItem(at: record.folder)
            total -= record.size
        }
    }

    private struct ArtifactRecord {
        let folder: URL
        let size: Int64
        let modified: Date
        let active: Bool
    }

    private func prepareForIncoming(byteCount: Int64, additionalDiskBytes: Int64) throws {
        guard byteCount >= 0,
              byteCount <= Int64(maximumBytes),
              byteCount <= maximumTotalBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        try ensureRoot()
        try prune()
        var records = try artifactRecords(removingMalformed: true)
        let reservedBytes = try Self.checkedTotal(reservations.values)
        var total = try Self.checkedTotal(records.map(\.size), startingAt: reservedBytes)
        while records.count + reservations.count + 1 > maximumArtifacts
            || Self.exceeds(total, adding: byteCount, limit: maximumTotalBytes) {
            guard let index = records.firstIndex(where: { !$0.active }) else {
                throw URLError(.cannotCreateFile)
            }
            let record = records.remove(at: index)
            try FileManager.default.removeItem(at: record.folder)
            total -= record.size
        }
        if additionalDiskBytes > 0,
           let available = try root.resourceValues(forKeys: [
               .volumeAvailableCapacityForImportantUsageKey,
           ]).volumeAvailableCapacityForImportantUsage,
           Self.exceeds(
               additionalDiskBytes,
               adding: SessionExportArtifactPolicy.minimumFreeBytes,
               limit: available
           ) {
            throw URLError(.cannotCreateFile)
        }
    }

    private static func checkedTotal<S: Sequence>(
        _ values: S,
        startingAt initial: Int64 = 0
    ) throws -> Int64 where S.Element == Int64 {
        var total = initial
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow, value >= 0 else { throw URLError(.cannotCreateFile) }
            total = next
        }
        return total
    }

    private static func exceeds(_ value: Int64, adding increment: Int64, limit: Int64) -> Bool {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow || increment < 0 || sum > limit
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let admitted = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard admitted.isDirectory == true, admitted.isSymbolicLink != true else {
            throw URLError(.cannotCreateFile)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    private func artifactRecords(removingMalformed: Bool) throws -> [ArtifactRecord] {
        let activeFolders = Set(activeArtifacts.map { $0.deletingLastPathComponent().standardizedFileURL })
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var records: [ArtifactRecord] = []
        for folder in children {
            let folderValues = try? folder.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            let active = activeFolders.contains(folder.standardizedFileURL)
            guard folderValues?.isDirectory == true,
                  folderValues?.isSymbolicLink != true,
                  let modified = folderValues?.contentModificationDate,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: folder,
                      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                      options: [.skipsHiddenFiles]
                  ),
                  files.count == 1,
                  let file = files.first,
                  let fileValues = try? file.resourceValues(forKeys: [
                      .fileSizeKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                  ]),
                  fileValues.isRegularFile == true,
                  fileValues.isSymbolicLink != true,
                  let size = fileValues.fileSize,
                  size >= 0,
                  size <= maximumBytes else {
                if removingMalformed && !active { try? FileManager.default.removeItem(at: folder) }
                continue
            }
            records.append(ArtifactRecord(folder: folder, size: Int64(size), modified: modified, active: active))
        }
        return records.sorted { $0.modified < $1.modified }
    }

    nonisolated static func safeFilename(_ input: String) -> String {
        let lastComponent = (input as NSString).lastPathComponent
        var value = String(lastComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "." || value == ".." || value.contains("/") || value.contains("\\") {
            value = "export"
        }
        while value.utf8.count > SessionExportArtifactPolicy.maximumFilenameBytes {
            value.removeLast()
        }
        return value.isEmpty ? "export" : value
    }
}
