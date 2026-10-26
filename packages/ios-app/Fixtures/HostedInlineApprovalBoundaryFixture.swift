#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Production Changes decision sheet against HostedSettingsRendererSocket's RPC path.
/// This is a frontend boundary fixture, not a real-Gateway delivery proof.
struct HostedInlineApprovalBoundaryFixture: View {
    @State private var routes = ChatTranscriptSheetRouteOwner()

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
                Button("Review pending request") {
                    routes.present(.settingsApproval(.request(SettingsApprovalReference(requestID: "approve", changeIDs: ["pending-approve"]))))
                }
                .accessibilityIdentifier("fixture-review-pending-approval")
                if let outcome { SettingsApprovalOutcomeChip(message: outcome) }
            }.padding(18)
        }
        .environment(\.chatTranscriptSheetRoutes, routes)
        .modifier(ChatTranscriptSheetHost(routes: routes))
    }
}
#endif
