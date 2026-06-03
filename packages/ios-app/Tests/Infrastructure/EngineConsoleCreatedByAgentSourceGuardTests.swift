import Foundation
import Testing

@Suite("Engine Console Created by Agent Source Guards")
struct EngineConsoleCreatedByAgentSourceGuardTests {
    @Test("Created by Agent shelf stays server-derived and product-labeled")
    func testCreatedByAgentShelfBoundary() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engineConsole = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/EngineConsole/EngineConsoleView.swift"),
            encoding: .utf8
        )
        let engineConsoleState = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/State/EngineConsoleState.swift"),
            encoding: .utf8
        )
        let projection = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/State/EngineConsoleCreatedByAgentProjection.swift"),
            encoding: .utf8
        )
        let view = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/EngineConsole/EngineConsoleCreatedByAgentView.swift"),
            encoding: .utf8
        )

        #expect(engineConsole.contains("EngineConsoleCreatedByAgentCard(projection: state.createdByAgentProjection)"))
        #expect(
            engineConsole.range(of: "EngineConsoleCreatedByAgentCard(projection: state.createdByAgentProjection)")?.lowerBound
                ?? engineConsole.endIndex
                < (engineConsole.range(of: "EngineConsoleMetricGrid(metrics: substrateMetrics)")?.lowerBound
                    ?? engineConsole.endIndex)
        )
        #expect(engineConsoleState.contains("EngineConsoleCreatedByAgentProjection.make("))
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
        #expect(view.contains(#"title: "Created by Agent""#))
        #expect(view.contains("historyLabels"))
        #expect(view.contains(".accessibilityValue(change.accessibilityValue)"))

        let productionSources = [engineConsole, engineConsoleState, projection, view].joined(separator: "\n")
        #expect(!productionSources.contains("EngineConsoleHarnessChange"))
        #expect(!productionSources.contains("Harness Changes"))
    }
}
