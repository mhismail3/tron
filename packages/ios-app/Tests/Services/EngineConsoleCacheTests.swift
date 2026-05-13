import Foundation
import Testing
@testable import TronMobile

@Suite("EngineConsoleCache")
struct EngineConsoleCacheTests {
    @Test("round trips redacted cache snapshot")
    func roundTripsSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("EngineConsoleCache.json")
        let cache = EngineConsoleCache(fileURL: url)
        let snapshot = EngineConsoleCacheSnapshot(
            catalogRevision: 7,
            registryRevision: nil,
            pluginSummaries: [
                CapabilityPluginManifestDTO(
                    id: "first_party.filesystem",
                    name: "Filesystem",
                    version: "1",
                    publisher: "Tron",
                    signatureStatus: "valid",
                    runtime: "in_process",
                    namespaceClaims: ["filesystem"],
                    providedContracts: ["filesystem::read_file"],
                    providedImplementations: ["first_party.filesystem.v1.read_file"],
                    requestedAuthorities: [],
                    trustTier: "first_party_signed",
                    visibilityCeiling: "system",
                    conformanceState: "healthy",
                    docs: nil,
                    examples: [],
                    searchMetadata: nil
                )
            ],
            workerSummaries: [],
            recentAuditRows: [
                CapabilityAuditEventDTO(
                    id: "audit-1",
                    eventType: "capability.execute",
                    traceId: "trace-1",
                    payload: nil,
                    payloadSummary: nil,
                    createdAt: nil,
                    redacted: true
                )
            ],
            recentTraceSummaries: [],
            recentProgramRuns: [],
            indexStatus: CapabilityIndexStatusDTO(
                lexical: true,
                localVector: true,
                cloudEmbeddings: false,
                vectorStore: "sqlite-vec",
                embeddingModel: "test",
                state: "ready",
                degradedReason: nil,
                dimension: nil,
                updatedAt: nil
            ),
            fetchedAt: Date()
        )

        try cache.save(snapshot)
        let loaded = try #require(cache.load())

        #expect(loaded.catalogRevision == 7)
        #expect(loaded.pluginSummaries.first?.id == "first_party.filesystem")
        #expect(loaded.recentAuditRows.first?.redacted == true)
    }
}
