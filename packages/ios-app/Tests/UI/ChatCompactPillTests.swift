import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Chat compact pill and prompt typography")
struct ChatCompactPillTests {
    @Test("prompt lines use logical leading alignment inside a right-anchored bound")
    func promptAlignment() {
        #expect(UserPromptTextLayoutPolicy.alignment(layoutDirection: .leftToRight) == .left)
        #expect(UserPromptTextLayoutPolicy.alignment(layoutDirection: .rightToLeft) == .right)
    }

    @Test("prompt bound, response-matched type scale, and glass geometry are explicit")
    func promptGeometry() {
        #expect(UserPromptTextLayoutPolicy.maximumWidth == 364)
        #expect(UserPromptTextLayoutPolicy.fontScale == 1)
        #expect(ChatPromptContainerStyle.cornerRadius == 18)
        #expect(ChatPromptContainerStyle.horizontalPadding == 12)
        #expect(ChatPromptContainerStyle.topPadding == 8)
        #expect(ChatPromptContainerStyle.userPromptBottomPadding == 8)
        #expect(ChatPromptContainerStyle.queuedMessageBottomPadding == 12)
        #expect(ChatPromptContainerStyle.tintOpacity == 0.16)
    }

    @Test("short prompts keep their intrinsic width while long prompts stop at the bound")
    func promptFittedWidth() {
        #expect(UserPromptTextLayoutPolicy.fittedWidth(measured: 96, proposed: 364) == 96)
        #expect(UserPromptTextLayoutPolicy.fittedWidth(measured: 520, proposed: 364) == 364)
    }

    @Test("bottom activity blur follows keyboard focus without changing layout")
    func bottomActivityBlurGeometry() {
        #expect(ChatBottomActivityBlurLayout.height(keyboardVisible: false) == 68)
        #expect(ChatBottomActivityBlurLayout.translation(keyboardVisible: false) == 44)
        #expect(ChatBottomActivityBlurLayout.height(keyboardVisible: true) == 80)
        #expect(ChatBottomActivityBlurLayout.translation(keyboardVisible: true) == 24)
        #expect(
            ChatBottomActivityBlurLayout.height(keyboardVisible: true)
                - ChatBottomActivityBlurLayout.translation(keyboardVisible: true)
                == 56
        )
    }

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

    @Test("Manage Session context usage never fabricates missing evidence")
    func sessionContextUsage() {
        #expect(SessionContextUsagePresentation(nil) == .unavailable)
        #expect(SessionContextUsagePresentation(.init(tokens: nil, contextWindow: 1_000, percent: nil)) == .unavailable)
        #expect(SessionContextUsagePresentation(.init(tokens: 250, contextWindow: 1_000, percent: 25)) == .available(used: 250, window: 1_000, percent: 25))
        #expect(SessionContextUsagePresentation(nil).accessibilityLabel.hasPrefix("Context usage:"))
    }

    @Test("Manage Session Git loading preserves branch evidence and exact request ownership")
    func sessionGitPresentation() {
        #expect(SessionGitPresentation.resolve(.init(isRepository: false, branch: nil, isDirty: false)) == .notRepository)
        #expect(SessionGitPresentation.resolve(.init(isRepository: true, branch: "main", isDirty: false)) == .loaded(branch: "main", dirty: false))
        #expect(SessionGitPresentation.resolve(.init(isRepository: true, branch: "feature", isDirty: true)) == .loaded(branch: "feature", dirty: true))
        #expect(SessionGitLoadAdmission.admits(requestGeneration: 3, currentGeneration: 3, requestedCwd: "/a", currentCwd: "/a"))
        #expect(!SessionGitLoadAdmission.admits(requestGeneration: 1, currentGeneration: 3, requestedCwd: "/a", currentCwd: "/a"))
        #expect(!SessionGitLoadAdmission.admits(requestGeneration: 3, currentGeneration: 3, requestedCwd: "/b", currentCwd: "/a"))
    }

    @Test("Agent Context summarizes capabilities without retaining inventories")
    func agentContextSummary() {
        let summary = AgentContextSummary(context: .object([
            "systemPrompt": .string(String(repeating: "a", count: 1_000)),
            "activeTools": .array([.string("read"), .string("edit")]),
            "availableTools": .array([.object(["name": .string("read")]), .object(["name": .string("edit")]), .object(["name": .string("bash")])]),
            "commands": .array([.string("one")]),
            "stats": .object(["totalMessages": .number(8), "toolCalls": .number(3)]),
            "contextUsage": .object(["tokens": .number(120), "contextWindow": .number(1_000)]),
        ]))

        #expect(summary.activeToolCount == 2)
        #expect(summary.availableToolCount == 3)
        #expect(summary.commandCount == 1)
        #expect(summary.messageCount == 8)
        #expect(summary.toolCallCount == 3)
        #expect(summary.contextTokens == 120)
        #expect(summary.contextWindow == 1_000)
        #expect(summary.instructionPreview.count == AgentContextSummary.maximumInstructionPreviewCharacters + 1)
    }

    @Test("Session History modes, fork points, and continuation impact are explicit")
    func sessionHistoryPolicy() {
        let prompt = historyNode(id: "prompt", role: .user, current: true)
        let response = historyNode(id: "response", role: .assistant, current: true)
        let earlier = historyNode(id: "earlier", role: .user, current: false)
        let earlierResponse = historyNode(id: "earlier-response", role: .assistant, current: false)
        let bookmark = historyNode(id: "bookmark", label: "Checkpoint", role: .assistant, current: true)
        let labelEvent = historyNode(id: "label-event", kind: "label", current: true)
        let technical = historyNode(id: "tool", kind: "tool", role: .toolResult, current: true)
        let nodes = [prompt, response, earlier, earlierResponse, bookmark, labelEvent, technical]

        #expect(SessionHistoryPolicy.nodes(nodes, mode: .timeline).map(\.id) == ["prompt", "response", "bookmark", "label-event"])
        #expect(SessionHistoryPolicy.nodes(nodes, mode: .branches).map(\.id) == ["earlier", "earlier-response"])
        #expect(SessionHistoryPolicy.nodes(nodes, mode: .bookmarks).map(\.id) == ["bookmark"])
        #expect(SessionHistoryPolicy.nodes(nodes, mode: .recentLog).count == 7)
        #expect(SessionHistoryPolicy.forkPoints(nodes).map(\.id) == ["earlier", "prompt"])
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

    @Test("compact transcript pills retain pre-shared vertical rhythm")
    func compactPillGeometry() {
        #expect(ChatCompactPillLayoutPolicy.horizontalPadding == 11)
        #expect(ChatCompactPillLayoutPolicy.verticalPadding == 6)
        #expect(ChatCompactPillLayoutPolicy.itemSpacing == 7)
        #expect(ChatCompactPillLayoutPolicy.standardIconSize == 10)
        #expect(ChatCompactPillLayoutPolicy.toolIconSize == 11)
    }

    @Test("small warning and neutral text keeps accessible contrast")
    @MainActor func compactToneContrast() {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightBackground = UIColor(hex: "#F7F8FA")
        let darkBackground = UIColor(hex: "#090A0C")

        for tone in [ChatNotificationTone.warning, .neutral] {
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

    @Test("notification material exposes details only through glass buttons")
    func notificationDetailPolicy() {
        let flat = ChatNotificationPresentation(
            id: "flat", semanticID: nil, icon: "info.circle", title: "Status",
            detail: nil, body: nil, tone: .information, material: .flat
        )
        let glass = ChatNotificationPresentation(
            id: "glass", semanticID: "entry", icon: "arrow.triangle.branch",
            title: "Branch summary", detail: nil, body: "Summary",
            tone: .accent, material: .glass
        )
        let emptyGlass = ChatNotificationPresentation(
            id: "empty", semanticID: nil, icon: "info.circle", title: "Empty",
            detail: nil, body: nil, tone: .accent, material: .glass
        )

        #expect(!flat.hasDetailSheet)
        #expect(glass.hasDetailSheet)
        #expect(!emptyGlass.hasDetailSheet)
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
