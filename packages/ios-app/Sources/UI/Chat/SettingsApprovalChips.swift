import SwiftUI
import TronMobileCore

/// The one approval chip (#2050): an agent's request in its chat, a waiting row
/// in Changes, and a delivered outcome all render this pill and open the shared
/// approval sheet.
struct SettingsApprovalChip: View {
    let title: String
    let status: String
    /// Nil when only the request's identity is known (it left the open list).
    let count: Int?
    let identifier: String
    let action: () -> Void

    init(review: SettingsApprovalReview, identifier: String, action: @escaping () -> Void) {
        title = review.heading == "Change" || review.heading == "Changes" ? review.rows.map(\.title).joined(separator: ", ") : review.heading
        status = review.status; count = max(1, review.rows.count); self.identifier = identifier; self.action = action
    }

    init(title: String, status: String, count: Int?, identifier: String, action: @escaping () -> Void) {
        self.title = title; self.status = status; self.count = count; self.identifier = identifier; self.action = action
    }

    static func tone(_ status: String) -> ChatNotificationTone {
        switch status {
        case "pending": .warning
        case "approved": .success
        case "failed": .error
        default: .neutral
        }
    }

    static func accent(_ status: String) -> Color {
        switch status {
        case "pending": .tronAmber
        case "approved": .tronSuccess
        case "failed": .tronError
        default: .tronSlate
        }
    }

    private var detail: String {
        [SettingsApprovalReview.statusLabel(status), count.map { "\($0) \($0 == 1 ? "change" : "changes")" }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            ChatCompactPillSurface(tone: Self.tone(status), material: .glass, interactive: true,
                                   cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius) {
                ChatCompactPillLabel(icon: status == "pending" ? "checkmark.shield" : "shield.lefthalf.filled", title: title,
                                     detail: detail, tone: Self.tone(status),
                                     iconSize: ChatCompactPillLayoutPolicy.toolIconSize) { EmptyView() }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint(status == "pending" ? "Reviews the request" : "Shows the outcome")
        .accessibilityIdentifier(identifier)
    }
}

/// An agent tool call's request in the chat that asked. The open-request
/// projection decides whether it is still waiting; otherwise the status a
/// resolution named or the tool's own terminal result shows.
struct SettingsApprovalRequestChip: View {
    let requestID: String
    /// The tool result's status and title, before or without the projection.
    let toolStatus: String?
    let fallbackTitle: String
    @Environment(AppModel.self) private var model
    @Environment(\.chatTranscriptSheetRoutes) private var routes

    var body: some View {
        let open = model.openSettingsApprovals?.first { $0.requestId == requestID }
        let status = open != nil ? "pending" : model.settingsApprovalOutcome(requestID)
            ?? toolStatus.flatMap { SettingsApprovalOutcome.terminalStatuses.contains($0) ? $0 : nil }
            ?? (model.openSettingsApprovals == nil ? (toolStatus ?? "pending") : "decided")
        Group {
            if let open {
                SettingsApprovalChip(review: SettingsApprovalReview(request: open), identifier: "settings-approval-chip-\(requestID)", action: present)
            } else {
                SettingsApprovalChip(title: fallbackTitle, status: status, count: nil, identifier: "settings-approval-chip-\(requestID)", action: present)
            }
        }
        .disabled(routes == nil)
        .task(id: model.settingsApprovalsRevision) { try? await model.refreshSettingsApprovals() }
    }

    private func present() {
        routes?.present(.settingsApproval(.request(SettingsApprovalReference(requestID: requestID, changeIDs: []))))
    }
}

/// A delivered `tron.settings-outcome.v1` message: the same chip, its outcomes.
struct SettingsApprovalOutcomeChip: View {
    let message: SettingsApprovalOutcomeMessage
    @Environment(\.chatTranscriptSheetRoutes) private var routes

    var body: some View {
        let statuses = Set(message.requests.map(\.status))
        SettingsApprovalChip(title: message.requests.count == 1 ? message.requests[0].action?.title ?? message.requests[0].items.map(\.label).joined(separator: ", ") : "Settings outcomes",
                             status: statuses.count == 1 ? message.requests[0].status : statuses.contains("failed") ? "failed" : "decided",
                             count: message.itemCount, identifier: "settings-outcome-chip-\(message.eventID)") {
            routes?.present(.settingsApproval(.outcomes(message)))
        }
        .disabled(routes == nil)
    }
}
