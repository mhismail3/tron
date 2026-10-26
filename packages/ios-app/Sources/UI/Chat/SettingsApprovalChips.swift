import SwiftUI

struct SettingsApprovalOutcomeChip: View {
    let message: SettingsApprovalOutcomeMessage
    @Environment(\.chatTranscriptSheetRoutes) private var routes

    private var tone: ChatNotificationTone {
        let statuses = Set(message.requests.map(\.status))
        if statuses.contains("failed") { return .error }
        if statuses == ["approved"] { return .success }
        return .neutral
    }

    var body: some View {
        Button { routes?.present(.settingsApproval(.outcomes(message))) } label: {
            ChatCompactPillSurface(tone: tone, material: .glass, interactive: true,
                                   cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius) {
                ChatCompactPillLabel(icon: "checkmark.shield", title: message.title,
                                    detail: "\(message.itemCount) \(message.itemCount == 1 ? "change" : "changes")", tone: tone,
                                    iconSize: ChatCompactPillLayoutPolicy.toolIconSize) { EmptyView() }
            }
        }
        .buttonStyle(.plain)
        .disabled(routes == nil)
        .accessibilityLabel("\(message.title), \(message.itemCount) changes")
        .accessibilityHint("Shows the recorded outcomes")
        .accessibilityIdentifier("settings-outcome-chip-\(message.eventID)")
    }
}
