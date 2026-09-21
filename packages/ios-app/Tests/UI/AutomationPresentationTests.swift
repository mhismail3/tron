import Testing
@testable import TronMobile

@MainActor
struct AutomationPresentationTests {
    @Test func inventoryAndDetailShareSummaryFacts() throws {
        let record = try AutomationPresentationFixture.record()
        #expect(AutomationAdmissionPolicy.admits(record))
        let summary = try AutomationPresentationFixture.summary(record)
        let inventory = AutomationSummaryPresentation(summary: summary, server: "Studio server")
        let detail = AutomationSummaryPresentation(record: record, server: "Studio server")
        #expect(inventory.accessibilityLabel == detail.accessibilityLabel)
        #expect(detail.name == "Daily workspace review")
        #expect(detail.icon == "text.bubble")
        #expect(detail.status == "Draft")
        #expect(detail.cadence == "Every 1 day")
        #expect(detail.server == "Studio server")
        #expect(detail.lastRunAt == AutomationPresentationFixture.startedAt)
        #expect(detail.lastRunAt != AutomationPresentationFixture.terminalAt)
        #expect(detail.updatedAt == AutomationPresentationFixture.updatedAt)
        #expect(detail.accessibilityLabel.contains("Last run"))
        #expect(detail.accessibilityLabel.contains("Updated"))
    }

    @Test func neverRunDoesNotBorrowTheNextOccurrence() throws {
        let record = try AutomationPresentationFixture.record(last: false, notification: true)
        let presentation = AutomationSummaryPresentation(record: record, server: "Studio server")
        #expect(record.nextOccurrenceAt != nil)
        #expect(presentation.lastRunAt == nil)
        #expect(presentation.icon == "bell")
        #expect(presentation.accessibilityLabel.contains("No runs yet"))
        let inventory = AutomationSummaryPresentation(summary: try AutomationPresentationFixture.summary(record), server: "Studio server")
        #expect(inventory.lastRunAt == nil)
    }

    @Test func activeExecutionDoesNotHideActivationAndUsesLatestStart() throws {
        let record = try AutomationPresentationFixture.record(activation: "paused", current: true)
        let detail = AutomationSummaryPresentation(record: record, server: "Studio server")
        #expect(detail.status == "Paused · Running")
        #expect(detail.lastRunAt == "2026-09-20T09:00:02Z")
        let inventory = AutomationSummaryPresentation(summary: try AutomationPresentationFixture.summary(record), server: "Studio server")
        #expect(inventory.accessibilityLabel == detail.accessibilityLabel)
    }

    @Test func attentionRemainsVisibleAndAccessible() throws {
        let record = try AutomationPresentationFixture.record(activation: "blocked")
        let presentation = AutomationSummaryPresentation(record: record, server: "Studio server")
        #expect(presentation.needsAttention)
        #expect(presentation.status == "Needs attention")
        #expect(presentation.blockedReason == "outcome-unknown")
        #expect(presentation.accessibilityLabel.contains("2 consecutive failures"))
    }

    @Test func detailTablesPreserveOtherFactsWithoutSummaryDuplicatesOrActions() throws {
        let record = try AutomationPresentationFixture.record(current: true)
        let sections = AutomationDetailMetadata.sections(record: record, targetLabel: "Review session")
        #expect(sections.map(\.title) == ["Action", "Schedule", "Target", "Current run", "About"])
        let rows = sections.flatMap(\.rows)
        #expect(rows.allSatisfy { $0.type == nil && $0.icon == nil })
        let titles = Set(rows.map(\.title))
        #expect(titles.isDisjoint(with: ["Status", "Runs", "Cadence", "Last run", "Updated", "Server", "Gateway", "Started"]))
        #expect(titles.isSuperset(of: ["Prompt", "Series", "Timezone", "After downtime", "While running", "Deadline", "Next", "Session", "Scheduled", "Created", "Created by", "Revision"]))
        #expect(rows.first { $0.title == "Prompt" }?.value == record.action.content)
        #expect(rows.first { $0.title == "Created by" }?.value == "Mac")
        #expect(rows.first { $0.title == "Session" }?.value == "Review session")
        #expect(rows.first { $0.title == "Revision" }?.value == "2")
    }

    @Test func descriptionAndPromptTemplateHaveDistinctStableRows() throws {
        let original = try AutomationPresentationFixture.record()
        var fields = try JSONValue.encode(original).objectValue!
        fields["description"] = .string("Summarize repository changes each morning.")
        var action = try JSONValue.encode(original.action).objectValue!
        action["resourceInvocation"] = try JSONValue.encode(ComposerResourceInvocation(
            source: .prompt, name: "daily-review", arguments: original.action.content
        ))
        fields["action"] = .object(action)
        let record = try JSONValue.object(fields).decode(GatewayAutomationRecord.self)
        #expect(AutomationAdmissionPolicy.admits(record))
        let sections = AutomationDetailMetadata.sections(record: record, targetLabel: "Review session")
        #expect(sections.first?.rows.first?.value == record.description)
        let rows = sections.first { $0.title == "Action" }!.rows
        #expect(rows.map(\.title) == ["Prompt", "Prompt template"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.last?.value == "daily-review")
    }

    @Test func workspaceAndNotificationDetailsKeepTheirOwnValues() throws {
        let workspace = try AutomationPresentationFixture.record(last: false, workspace: true)
        let rows = AutomationDetailMetadata.sections(record: workspace, targetLabel: "New session per run · project").flatMap(\.rows)
        #expect(rows.first { $0.title == "Workspace" }?.value == "/workspace/project")
        let notification = try AutomationPresentationFixture.record(last: false, notification: true)
        let action = AutomationDetailMetadata.sections(record: notification, targetLabel: "Review session").first
        #expect(action?.rows.first?.title == "Message")
        #expect(action?.rows.first?.value == "Review the weekly report.")
    }
}
