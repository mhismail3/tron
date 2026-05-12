import Foundation

struct EngineConsoleCacheSnapshot: Codable, Equatable, Sendable {
    var catalogRevision: UInt64?
    var registryRevision: UInt64?
    var pluginSummaries: [CapabilityPluginManifestDTO]
    var workerSummaries: [CapabilityIndexDocumentDTO]
    var recentAuditRows: [CapabilityAuditEventDTO]
    var recentTraceSummaries: [CapabilityAuditEventDTO]
    var indexStatus: CapabilityIndexStatusDTO?
    var fetchedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 60
    }
}

final class EngineConsoleCache {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = EngineConsoleCache.defaultFileURL()) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> EngineConsoleCacheSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(EngineConsoleCacheSnapshot.self, from: data)
    }

    func save(_ snapshot: EngineConsoleCacheSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func makeSnapshot(
        status: CapabilityStatusDTO?,
        registry: CapabilityRegistrySnapshotDTO?,
        audit: CapabilityAuditQueryResultDTO?
    ) -> EngineConsoleCacheSnapshot {
        let workers = registry?.documents?.filter { $0.kind == "worker" } ?? []
        let traces = audit?.events.filter { event in
            event.traceId?.isEmpty == false
        } ?? []
        return EngineConsoleCacheSnapshot(
            catalogRevision: status?.catalogRevision,
            registryRevision: status?.registryRevision,
            pluginSummaries: registry?.plugins ?? [],
            workerSummaries: workers,
            recentAuditRows: audit?.events ?? [],
            recentTraceSummaries: traces,
            indexStatus: status?.indexStatus,
            fetchedAt: Date()
        )
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("TronMobile", isDirectory: true)
            .appendingPathComponent("EngineConsoleCache.json")
    }
}
