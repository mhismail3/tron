import Foundation
import Testing

@Suite("Dashboard Presentation Tests")
struct DashboardPresentationTests {
    @Test("Dashboard uses actions and engine interfaces while technical IDs stay explicit")
    func dashboardUsesClearVocabularyAndSeparateIDs() throws {
        let discovery = try source("Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift")
        let detail = try source("Sources/UI/AgentCockpit/AgentCockpitOperationDetailViews.swift")
        let tabs = try source("Sources/UI/AgentCockpit/AgentCockpitTabViews.swift")

        #expect(discovery.contains(#"metric("Engine interfaces", "\(overview.engineFunctionCount)")"#))
        #expect(discovery.contains(#"detailMetric("Engine interfaces", group.functionCount)"#))
        #expect(discovery.contains(#"overview.capabilityVisibility == nil ? "—""#))
        #expect(tabs.contains(#"? "Action inventory unavailable""#))
        #expect(!discovery.contains(#"metric("Functions""#))
        #expect(!discovery.contains(#"detailMetric("Functions""#))
        #expect(discovery.contains("Agent actions are what the assistant can invoke."))
        #expect(discovery.contains(#"Text("Operation ID: \(operation.name)")"#))
        #expect(discovery.contains(#"Text("Function ID: \(function.id)")"#))
        #expect(!discovery.contains(#"Text("\(operation.name) · \(activitySummary)")"#))
        #expect(detail.contains(#"Text("Operation ID: \(operation.name)")"#))
        #expect(detail.contains(#"Text("Function ID: \(operation.id)")"#))
    }

    @Test("One large Dashboard summary owns cross-tab status and capability verification")
    func dashboardSummaryOwnsCrossTabStatus() throws {
        let summary = try source("Sources/UI/AgentCockpit/AgentCockpitSummaryViews.swift")
        let sheet = try source("Sources/UI/AgentCockpit/AgentCockpitViews.swift")
        let tabs = try source("Sources/UI/AgentCockpit/AgentCockpitTabViews.swift")
        let discovery = try source("Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift")
        let cardStart = try #require(summary.range(of: "struct AgentCockpitDashboardSummaryCard"))
        let card = summary[cardStart.lowerBound..<summary.endIndex]
        let activityStart = try #require(card.range(of: "private var activityDetail"))
        let statusColorStart = try #require(card.range(of: "private var statusColor"))
        let activityDetail = card[activityStart.lowerBound..<statusColorStart.lowerBound]

        #expect(card.contains(#"title: "Capabilities""#))
        #expect(card.contains(#"identifier: "dashboard-summary-capabilities""#))
        #expect(card.contains(#"singular: "agent action""#))
        #expect(card.contains(#"plural: "agent actions""#))
        #expect(card.contains("summary.triggers"))
        #expect(card.contains(#"title: "Engine""#))
        #expect(card.contains(#"singular: "engine action""#))
        #expect(card.contains(#"plural: "engine actions""#))
        #expect(card.contains("summary.engineInterfaces"))
        #expect(card.contains(#"title: "Recent activity""#))
        #expect(activityDetail.contains("summary.activeActivity > 0"))
        #expect(activityDetail.contains("summary.waitingActivity > 0"))
        #expect(activityDetail.contains("summary.blockedActivity > 0"))
        #expect(activityDetail.contains("summary.degradedActivity > 0"))
        #expect(!activityDetail.contains("summary.issues"))
        #expect(card.contains(#".accessibilityLabel("Check capabilities")"#))
        #expect(card.contains(".glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14"))
        #expect(card.contains("summaryDivider"))
        #expect(card.contains("trailingAction()\n                .padding(.top, 1)"))
        #expect(card.contains("HStack(alignment: .center, spacing: summaryIconTextSpacing)"))
        #expect(card.contains(".frame(width: summaryIconColumnWidth, height: summaryIconColumnWidth)"))
        #expect(card.contains(".padding(.leading, summaryTextLeadingInset)"))
        #expect(!card.contains("HStack(alignment: .firstTextBaseline"))
        #expect(card.contains("detail: engineInterfacePhrase"))
        #expect(!card.contains(".sectionFill(.tronEmerald"))
        #expect(!card.contains("AnyView"))
        #expect(!card.contains(#""Idle""#))
        #expect(sheet.contains("AgentCockpitDashboardSummaryCard(overview: viewModel.overview)"))
        #expect(!sheet.contains("AgentCockpitMetricStrip"))
        #expect(!tabs.contains("CapabilitiesSummaryCard"))
        #expect(!tabs.contains("WorkerTriggerExplanationCard"))
        #expect(!discovery.contains("struct CapabilitiesSummaryCard"))
        #expect(!discovery.contains("struct WorkerTriggerExplanationCard"))
        for topLevelSource in [summary, sheet, tabs, discovery] {
            #expect(!topLevelSource.contains(#""Areas""#))
        }
    }

    @Test("Capability card facts share the title column and omit projection artifacts")
    func capabilityCardFactsShareTitleColumn() throws {
        let discovery = try source("Sources/UI/AgentCockpit/AgentCockpitDiscoveryViews.swift")
        let groupStart = try #require(discovery.range(of: "struct CapabilityGroupCard"))
        let groupEnd = try #require(discovery.range(of: "struct CatalogVerificationRow"))
        let groupSource = discovery[groupStart.lowerBound..<groupEnd.lowerBound]
        let capabilityStart = try #require(groupSource.range(of: "case .capabilities:"))
        let engineStart = try #require(groupSource.range(of: "case .engine:"))
        let capabilityMetrics = groupSource[capabilityStart.lowerBound..<engineStart.lowerBound]

        #expect(groupSource.contains("LazyVGrid(columns: metricColumns, alignment: .leading"))
        #expect(groupSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(capabilityMetrics.contains(#"("Actions", "\(group.operationCount)")"#))
        #expect(capabilityMetrics.contains(#"("Ownership", group.ownerSummary)"#))
        #expect(!capabilityMetrics.contains(#"("Engine interfaces""#))
        #expect(!capabilityMetrics.contains("group.functionCount"))
        #expect(!capabilityMetrics.contains("group.workerCount"))
        #expect(!capabilityMetrics.contains("group.triggerCount"))
        #expect(!groupSource.contains("compactSummaryMetric"))
        #expect(groupSource.contains("if group.operationCount > 0"))
        #expect(groupSource.contains("if group.functionCount > 0"))
        #expect(groupSource.contains("if group.workerCount > 0"))
    }

    @Test("Dashboard bands use the session row icon and text grid")
    func dashboardBandsUseSessionRowGrid() throws {
        let briefing = try source("Sources/UI/AgentBriefing/AgentBriefingViews.swift")
        let dashboard = try source("Sources/UI/AgentCockpit/AgentCockpitSummaryViews.swift")
        let briefingStart = try #require(briefing.range(of: "struct AgentBriefingDashboardBand"))
        let briefingEnd = try #require(briefing.range(of: "private var title"))
        let dashboardStart = try #require(dashboard.range(of: "struct EngineCockpitDashboardBand"))
        let dashboardEnd = try #require(dashboard.range(of: "struct AgentCockpitDashboardSummaryCard"))
        let bands = [
            briefing[briefingStart.lowerBound..<briefingEnd.lowerBound],
            dashboard[dashboardStart.lowerBound..<dashboardEnd.lowerBound],
        ]

        for band in bands {
            #expect(band.contains("HStack(alignment: .top, spacing: SessionListLayout.iconTextSpacing)"))
            #expect(band.contains("width: SessionListLayout.iconColumnWidth"))
            #expect(band.contains("height: SessionListLayout.iconColumnWidth"))
            #expect(band.contains(".padding(.horizontal, SessionListLayout.rowContentHorizontalPadding)"))
        }
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: iosAppRoot().appendingPathComponent(path),
            encoding: .utf8
        )
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
