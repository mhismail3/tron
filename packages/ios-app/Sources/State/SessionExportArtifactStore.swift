import Foundation

enum SessionExportArtifactPolicy {
    static let maximumEncodedBytes = 25 * 1_048_576
    static let maximumFilenameBytes = 160
    static let maximumAge: TimeInterval = 24 * 60 * 60
}

actor SessionExportArtifactStore {
    private let root: URL
    private let maximumBytes: Int
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    init(
        root: URL = FileManager.default.temporaryDirectory.appending(
            path: "TronExports",
            directoryHint: .isDirectory
        ),
        maximumBytes: Int = SessionExportArtifactPolicy.maximumEncodedBytes,
        maximumAge: TimeInterval = SessionExportArtifactPolicy.maximumAge,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        precondition(maximumBytes >= 0)
        precondition(maximumAge >= 0)
        self.root = root
        self.maximumBytes = maximumBytes
        self.maximumAge = maximumAge
        self.now = now
        self.uuid = uuid
    }

    func write(_ data: Data, suggestedName: String) throws -> URL {
        guard data.count <= maximumBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        try prune()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var rootValues = URLResourceValues()
        rootValues.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(rootValues)

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
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func discard(_ artifact: URL) {
        let folder = artifact.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func prune() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let cutoff = now().addingTimeInterval(-maximumAge)
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true,
                  let modified = values?.contentModificationDate,
                  modified >= cutoff else {
                try? FileManager.default.removeItem(at: child)
                continue
            }
        }
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
