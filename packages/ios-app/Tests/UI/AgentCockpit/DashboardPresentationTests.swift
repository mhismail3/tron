import Foundation
import Testing

@Suite("Dashboard Presentation Tests")
struct DashboardPresentationTests {
    @Test("Dashboard cards keep function labels compact and technical IDs separate")
    func dashboardCardsKeepCompactLabelsAndSeparateIDs() throws {
        let iosRoot = iosAppRoot()
        let discovery = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift"),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/AgentCockpit/AgentCockpitOperationDetailViews.swift"),
            encoding: .utf8
        )

        #expect(discovery.contains(#"metric("Functions", overview.engineFunctionCount)"#))
        #expect(discovery.contains(#"detailMetric("Functions", group.functionCount)"#))
        #expect(!discovery.contains("Engine functions"))
        #expect(discovery.contains(#"Text("Operation ID: \(operation.name)")"#))
        #expect(discovery.contains(#"Text("Function ID: \(function.id)")"#))
        #expect(!discovery.contains(#"Text("\(operation.name) · \(activitySummary)")"#))
        #expect(detail.contains(#"Text("Operation ID: \(operation.name)")"#))
        #expect(detail.contains(#"Text("Function ID: \(operation.id)")"#))
    }

    private func iosAppRoot(filePath: String = #filePath) -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        preconditionFailure("Could not locate packages/ios-app from \(filePath)")
    }
}
