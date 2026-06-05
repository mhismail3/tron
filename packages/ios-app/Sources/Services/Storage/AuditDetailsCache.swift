import Foundation

struct AuditDetailsCacheSnapshot: Codable, Equatable, Sendable {
    var catalogRevision: UInt64?
    var registryRevision: UInt64?
    var pluginSummaries: [CapabilityPluginManifestDTO]
    var workerSummaries: [CapabilityIndexDocumentDTO]
    var controlSnapshot: ControlSnapshotDTO?
    var recentAuditRows: [CapabilityAuditEventDTO]
    var recentTraceSummaries: [CapabilityAuditEventDTO]
    var recentProgramRuns: [CapabilityProgramRunDTO]
    var indexStatus: CapabilityIndexStatusDTO?
    var fetchedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 60
    }
}

final class AuditDetailsCache {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = AuditDetailsCache.defaultFileURL()) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> AuditDetailsCacheSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(AuditDetailsCacheSnapshot.self, from: data)
    }

    func save(_ snapshot: AuditDetailsCacheSnapshot) throws {
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
        controlSnapshot: ControlSnapshotDTO?,
        audit: CapabilityAuditQueryResultDTO?,
        programRuns: CapabilityProgramRunQueryResultDTO? = nil
    ) -> AuditDetailsCacheSnapshot {
        let workers = registry?.documents?.filter { $0.kind == "worker" } ?? []
        let traces = audit?.events.filter { event in
            event.traceId?.isEmpty == false
        } ?? []
        return AuditDetailsCacheSnapshot(
            catalogRevision: status?.catalogRevision,
            registryRevision: status?.registryRevision,
            pluginSummaries: registry?.plugins ?? [],
            workerSummaries: workers,
            controlSnapshot: controlSnapshot,
            recentAuditRows: audit?.events ?? [],
            recentTraceSummaries: traces,
            recentProgramRuns: programRuns?.programRuns ?? registry?.programRuns ?? [],
            indexStatus: status?.indexStatus,
            fetchedAt: Date()
        )
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("TronMobile", isDirectory: true)
            .appendingPathComponent("AuditDetailsCache.json")
    }
}
