#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Production approval chip, sheet and Changes against HostedSettingsRendererSocket's
/// RPC path. This is a frontend boundary fixture, not a real-Gateway delivery proof.
struct HostedInlineApprovalBoundaryFixture: View {
    @State private var routes = ChatTranscriptSheetRouteOwner()
    @State private var changes = false

    static let failure = "Action execution was interrupted. Its effects may have completed. Inspect the affected state before retrying. This original diagnostic is retained in full, including the final instruction: verify the existing worktree before creating another one."
    /// #2050 previews: a chat with requests in both modes, decided and waiting.
    static var requestsPreview: Bool { ProcessInfo.processInfo.arguments.contains("-approval-requests-preview") }
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
                if Self.requestsPreview {
                    requestsChat
                } else {
                    Button("Review pending request") {
                        routes.present(.settingsApproval(.request(SettingsApprovalReference(requestID: "approve", changeIDs: ["pending-approve"]))))
                    }
                    .accessibilityIdentifier("fixture-review-pending-approval")
                    if let outcome { SettingsApprovalOutcomeChip(message: outcome) }
                }
            }.padding(18)
        }
        .environment(\.chatTranscriptSheetRoutes, routes)
        .modifier(ChatTranscriptSheetHost(routes: routes))
        .tronManagedSheet(isPresented: $changes, identity: "fixture.approval-changes") {
            SettingsChangesView(scope: .all)
        }
    }

    /// A chat-shaped column: Home's two requests (one waiting in the turn, one
    /// returned pending) and an earlier decided one, all as the shared chip.
    private var requestsChat: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sort my unsorted notes, and let this chat retry five times.")
                .font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
                .padding(14).background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.tronPrimary.opacity(0.14)))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Both need your approval, so I asked here. The profile sort waits for you; the retry change does not hold this turn.")
                .font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
            SettingsApprovalRequestChip(requestID: "profile-wait", toolStatus: nil, fallbackTitle: "Review exact profile changes")
            SettingsApprovalRequestChip(requestID: "settings-pending", toolStatus: "pending", fallbackTitle: "Retries")
            SettingsApprovalRequestChip(requestID: "earlier-applied", toolStatus: "approved", fallbackTitle: "Model, Thinking")
            Button("Open Changes") { changes = true }
                .accessibilityIdentifier("fixture-open-changes")
                .padding(.top, 24)
            Text("Design preview · fixture requests").font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
        }
    }
}
#endif
