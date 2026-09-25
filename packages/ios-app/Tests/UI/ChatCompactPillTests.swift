import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Chat compact pill and prompt typography")
struct ChatCompactPillTests {

    @Test("Manage Session compaction admission matches Gateway support")
    func sessionCompactionAdmission() {
        #expect(SessionCompactionControlPolicy.canRequest(phase: .idle, compactionQueued: false, submitting: false))
        #expect(SessionCompactionControlPolicy.canRequest(phase: .running, operationKind: .prompt, compactionQueued: false, submitting: false))
        #expect(!SessionCompactionControlPolicy.canRequest(phase: .running, operationKind: .bash, compactionQueued: false, submitting: false))
        #expect(SessionCompactionControlPolicy.canRequest(phase: .interrupted, compactionQueued: false, submitting: false))
        #expect(!SessionCompactionControlPolicy.canRequest(phase: .compacting, compactionQueued: false, submitting: false))
        #expect(!SessionCompactionControlPolicy.canRequest(phase: .retrying, compactionQueued: false, submitting: false))
        #expect(!SessionCompactionControlPolicy.canRequest(phase: .running, operationKind: .prompt, compactionQueued: true, submitting: false))
        #expect(!SessionCompactionControlPolicy.canRequest(phase: .idle, compactionQueued: false, submitting: true))
        #expect(!SessionCompactionControlPolicy.canRequest(phase: .idle, compactionQueued: false, submitting: false, exporting: true))
        #expect(SessionCompactionControlPolicy.visualState(compactionQueued: true, submitting: true, phase: .running) == .queued)
        #expect(SessionCompactionControlPolicy.visualState(compactionQueued: false, submitting: true, phase: .idle) == .inProgress)
        #expect(SessionCompactionControlPolicy.automaticStatus(true) == "Enabled")
        #expect(SessionCompactionControlPolicy.automaticStatus(false) == "Disabled")
        #expect(SessionCompactionControlPolicy.automaticStatus(nil) == "Unavailable")
    }

    @Test("Manage Session projection ignores streaming-only snapshot churn")
    func manageSessionProjectionIsNarrow() throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_701)
            .openingTail(targetEncodedBytes: 4_000)
        let baseline = SessionContextPresentation(snapshot)
        snapshot.streaming = SessionScenarioBuilder(seed: 7_702)
            .historyPage(count: 1, longRowBytes: 16)[0]
        #expect(SessionContextPresentation(snapshot) == baseline)

        snapshot.contextUsage = ContextUsage(tokens: 100, contextWindow: 1_000, percent: 10)
        #expect(SessionContextPresentation(snapshot) != baseline)
    }

    @Test("model summary uses the exact selected provider and catalog name with a stable fallback")
    func modelSummaryName() throws {
        let first = ModelSummary(provider: "first", id: "same-id", name: "First Model", reasoning: true, input: ["text"], contextWindow: 272_000, maxTokens: 8_192, available: true)
        let second = ModelSummary(provider: "second", id: "same-id", name: "Second Model", reasoning: true, input: ["text"], contextWindow: 272_000, maxTokens: 8_192, available: true)
        let catalog = [first, second]
        let context = SessionContextPresentation(try SessionScenarioBuilder(seed: 8_110).openingTail(targetEncodedBytes: 4_096))
        let displayed = SessionModelSelectionPresentation.displayed(
            pending: SessionPendingModelSelection(second.ref, snapshot: context), authoritative: first.ref
        )
        #expect(SessionModelSelectionPresentation.modelName(displayed, catalog: catalog) == "Second Model")
        #expect(SessionModelSelectionPresentation.modelName(first.ref, catalog: catalog) == "First Model")
        #expect(SessionModelSelectionPresentation.modelName(first.ref, catalog: []) == first.ref.displayName)
        #expect(SessionModelSelectionPresentation.modelName(nil, catalog: catalog) == "Choose model")
    }

    @Test("workspace history graph preserves branch and merge lanes")
    func workspaceHistoryGraph() {
        func commit(_ oid: String, parents: [String]) -> SessionWorkspaceCommit {
            SessionWorkspaceCommit(
                oid: oid,
                shortOid: oid,
                parents: parents,
                subject: oid,
                authorName: "Author",
                authoredAt: "2026-08-31T00:00:00Z",
                decorations: []
            )
        }
        let rows = WorkspaceHistoryGraphLayout.rows(for: [
            commit("merge", parents: ["left", "right"]),
            commit("left", parents: ["base"]),
            commit("right", parents: ["base"]),
            commit("base", parents: []),
        ])

        #expect(rows.count == 4)
        #expect(rows[0].nodeLane == 0)
        #expect(rows[0].parentLanes == [0, 1])
        #expect(rows[1].transitions.contains(WorkspaceHistoryGraphSegment(from: 1, to: 1)))
        #expect(rows[2].nodeLane == 1)
        #expect(rows[2].parentLanes == [0])
        #expect(rows[3].nodeLane == 0)
    }

    @Test("commit prose reflows without joining list items, code, quotes or trailers")
    func structuredCommitMessageBody() throws {
        let structured = "- First change\n- Second change\n\n> Quoted line\n> Next line\n\n~~~text\nfirst code line\nsecond code line\n~~~\n\nSigned-off-by: Example <example@example.invalid>\nReviewed-by: Reviewer <reviewer@example.invalid>"
        let source = "Fix wrapping\n\nA prose sentence\ncontinues here.\n\n" + structured
        let body = try #require(WorkspaceCommitMessagePresentation.body(subject: "Fix wrapping", message: source))
        #expect(MarkdownPresentation.reflowProse(body) == "A prose sentence continues here.\n\n" + structured)
        #expect(body.contains("A prose sentence\ncontinues here."))
    }

    @Test("Project prompts resolve content by exact loaded-template identity, not their display title or file path")
    func projectPromptContentIdentity() {
        let value: JSONValue = .object([
            "name": .string("test-suite-audit"),
            "description": .string("Review the tests."),
            "argumentHint": .string("[scope]"),
            "path": .string("/project/prompts/test-suite-audit.md"),
            "scope": .string("project"),
            "source": .string("auto"),
        ])
        let selection = ProjectResourceSelection(kind: .prompts, title: "Test Suite Audit", value: value)
        #expect(selection.commandInfo?.name == "test-suite-audit")
        #expect(selection.commandInfo?.source == .prompt)
        #expect(selection.commandInfo?.resourceScope == .project)
        #expect(selection.commandInfo?.argumentHint == "[scope]")
        #expect(ComposerResourceBadges.titles(origin: .topLevel, scope: .project) == ["Project"])
        #expect(ComposerResourceBadges.titles(origin: .topLevel, scope: .user) == ["User"])
        #expect(ComposerResourceBadges.titles(origin: .package, scope: .user).isEmpty)
        #expect(ComposerResourceBadges.titles(origin: nil, scope: nil).isEmpty)
        let skill = ProjectResourceSelection(kind: .skills, title: "Review", value: value)
        #expect(skill.commandInfo?.name == "skill:test-suite-audit")
        #expect(skill.commandInfo?.source == .skill)
        #expect(ProjectResourceSelection(kind: .tools, title: "Test", value: value).commandInfo == nil)
        #expect(ProjectResourceSelection(kind: .prompts, title: "Test", value: .object([
            "path": .string("/project/prompts/test.md"),
        ])).commandInfo == nil)
    }

    @Test("Session History fork points and continuation impact are explicit")
    func sessionHistoryPolicy() {
        let prompt = historyNode(id: "prompt", role: .user, current: true)
        let response = historyNode(id: "response", role: .assistant, current: true)
        let earlier = historyNode(id: "earlier", role: .user, current: false)
        let earlierResponse = historyNode(id: "earlier-response", role: .assistant, current: false)
        #expect(SessionHistoryPolicy.canNavigate(node: prompt, leafID: "response"))
        #expect(!SessionHistoryPolicy.canNavigate(node: response, leafID: "response"))
        #expect(SessionHistoryPolicy.canNavigate(node: historyNode(id: "leaf-prompt", role: .user, current: true), leafID: "leaf-prompt"))
        #expect(SessionHistoryPolicy.canNavigate(node: earlier, leafID: "response"))
        #expect(SessionHistoryPolicy.canNavigate(node: earlierResponse, leafID: "response"))
        #expect(SessionHistoryPolicy.leavesLaterWork(node: prompt, leafID: "response"))
        #expect(SessionHistoryPolicy.leavesLaterWork(node: earlier, leafID: "response"))
        #expect(SessionHistoryPolicy.leavesLaterWork(node: earlierResponse, leafID: "response"))
        #expect(!SessionHistoryPolicy.leavesLaterWork(node: response, leafID: "response"))
        #expect(!SessionHistoryPolicy.leavesLaterWork(node: historyNode(id: "leaf-prompt", role: .user, current: true), leafID: "leaf-prompt"))
        #expect(SessionHistoryPolicy.navigationTitle(for: prompt) == "Edit From This Prompt")
        #expect(SessionHistoryPolicy.navigationTitle(for: response) == "Continue From Here")
        #expect(SessionHistoryPreview.plain("# **Hello**\n> [world](https://example.test)\n- ~~again~~\n```swift") == "Hello world again swift")
    }

    @Test("small semantic text keeps accessible contrast")
    @MainActor func compactToneContrast() {
        #expect(ChatSemanticPillRole.tool.accent == .tronEmerald)
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightBackground = UIColor(hex: "#F7F8FA")
        let darkBackground = UIColor(hex: "#0D0E0F")

        for tone in [ChatNotificationTone.command, .tool, .information, .purple, .warning, .neutral] {
            for color in [tone.primaryColor, tone.secondaryColor] {
                #expect(contrastRatio(
                    UIColor(color).resolvedColor(with: lightTraits),
                    lightBackground
                ) >= 4.5)
                #expect(contrastRatio(
                    UIColor(color).resolvedColor(with: darkTraits),
                    darkBackground
                ) >= 4.5)
            }
        }
    }

    private func historyNode(
        id: String,
        kind: String = "message",
        label: String? = nil,
        role: TranscriptItem.Role? = nil,
        current: Bool
    ) -> SessionTreeNode {
        SessionTreeNode(
            id: id,
            parentId: nil,
            timestamp: "2026-08-17T00:00:00.000Z",
            kind: kind,
            label: label,
            preview: id,
            role: role,
            depth: 0,
            childCount: 0,
            isCurrentPath: current
        )
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
