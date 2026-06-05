import Foundation
import Testing

@Suite("Audit Details Worker Artifacts Source Guards")
struct AuditDetailsWorkerArtifactSourceGuardTests {
    @Test("Worker Artifacts shelf stays server-derived and product-labeled")
    func testWorkerArtifactShelfBoundary() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let auditDetails = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/AuditDetails/AuditDetailsView.swift"),
            encoding: .utf8
        )
        let auditDetailsState = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/State/AuditDetailsState.swift"),
            encoding: .utf8
        )
        let projection = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/State/AuditDetailsWorkerArtifactProjection.swift"),
            encoding: .utf8
        )
        let view = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/AuditDetails/AuditDetailsWorkerArtifactView.swift"),
            encoding: .utf8
        )

        #expect(auditDetails.contains("AuditDetailsWorkerArtifactCard(projection: state.workerArtifactProjection)"))
        #expect(
            auditDetails.range(of: "AuditDetailsWorkerArtifactCard(projection: state.workerArtifactProjection)")?.lowerBound
                ?? auditDetails.endIndex
                < (auditDetails.range(of: "AuditDetailsMetricGrid(metrics: substrateMetrics)")?.lowerBound
                    ?? auditDetails.endIndex)
        )
        #expect(auditDetailsState.contains("AuditDetailsWorkerArtifactProjection.make("))
        #expect(projection.contains("registry?.implementations"))
        #expect(projection.contains("catalogImplementations(from: catalogSnapshot)"))
        #expect(projection.contains("catalogSnapshot?.snapshot?.functions"))
        #expect(projection.contains("controlSnapshot?.uiSurfaceRefs"))
        #expect(projection.contains("audit?.events"))
        #expect(projection.contains("programRuns?.programRuns"))
        #expect(projection.contains(#"implementation.visibility?.lowercased() == "session""#))
        #expect(projection.contains("shelfTitle"))
        #expect(projection.contains("shelfSubtitle"))
        #expect(projection.contains("historyLabels"))
        #expect(view.contains(#"title: "Worker Artifacts""#))
        #expect(view.contains("historyLabels"))
        #expect(view.contains(".accessibilityValue(change.accessibilityValue)"))

        let productionSources = [auditDetails, auditDetailsState, projection, view].joined(separator: "\n")
        #expect(!productionSources.contains("AuditDetailsHarnessChange"))
        #expect(!productionSources.contains("Harness Changes"))
    }
}
