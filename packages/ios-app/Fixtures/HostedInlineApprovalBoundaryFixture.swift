#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Production chips/sheet against HostedSettingsRendererSocket's real RPC path.
/// This is a frontend boundary fixture, not a real-Gateway delivery proof.
struct HostedInlineApprovalBoundaryFixture: View {
    @State private var routes = ChatTranscriptSheetRouteOwner()

    private var requestTool: ChatToolPresentation {
        ChatToolPresentation(id: "approval-tool", title: "Settings", toolName: "settings", subtitle: "Completed",
            request: .object(["action": .string("request")]),
            response: .object(["status": .string("pending"), "tier": .string("approve"),
                "requestId": .string("approve"), "changes": .array([.object(["changeId": .string("pending-approve")])])]),
            content: "", fallbackContent: nil, error: false, startedAt: nil, completedAt: nil,
            durationMs: nil, lastProgressAt: nil, progressSequence: nil)
    }
    static let failure = "Action execution was interrupted. Its effects may have completed. Inspect the affected state before retrying. This original diagnostic is retained in full, including the final instruction: verify the existing worktree before creating another one."
    private var outcome: SettingsApprovalOutcomeMessage? {
        SettingsApprovalOutcomeMessage(details: .object([
            "version": .number(1), "eventId": .string("fixture-outcome"), "taskId": .string("fixture-delivery"),
            "requests": .array([.object([
                "requestId": .string("settled"), "status": .string("failed"),
                "requester": .object(["kind": .string("worker"), "taskId": .string("fixture-task")]),
                "target": .object(["kind": .string("global")]), "createdAt": .string("2026-01-01T12:00:00Z"),
                "failure": .string(Self.failure), "items": .array([.object([
                    "key": .string("secret"), "label": .string("Hidden setting"), "layer": .string("global"), "redacted": .bool(true)
                ])])
            ])])
        ]))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ToolCard(data: requestTool)
                if let outcome { SettingsApprovalOutcomeChip(message: outcome) }
            }.padding(18)
        }
        .environment(\.chatTranscriptSheetRoutes, routes)
        .modifier(ChatTranscriptSheetHost(routes: routes))
    }
}
#endif
