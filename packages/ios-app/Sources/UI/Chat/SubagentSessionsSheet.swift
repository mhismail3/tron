import SwiftUI

struct SubagentSessionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String

    private var subagents: [SessionSummary] {
        model.originatingSubagents(for: sessionID)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if subagents.isEmpty {
                        TronGlassCard(accent: .tronSlate) {
                            VStack(spacing: 10) {
                                Image(systemName: "person.2.badge.gearshape")
                                    .font(TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold))
                                    .foregroundStyle(Color.tronTextMuted)
                                Text("No subagent sessions")
                                    .font(TronTypography.headline)
                                Text("Current and completed subagents originating from this session appear here.")
                                    .font(TronTypography.bodySM)
                                    .foregroundStyle(Color.tronTextSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        sessionGroup(subagents)
                    }
                }
                .padding(18)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Subagents", accent: .tronPurple) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
    }

    private func sessionGroup(_ sessions: [SessionSummary]) -> some View {
        TronSettingsGroup("Current and Past", accent: .tronPurple) {
            VStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { TronSettingsDivider(accent: .tronPurple) }
                    TronSettingsRow(
                        icon: "person.2.badge.gearshape",
                        title: session.title,
                        subtitle: "\(session.relativeActivityDescription())\n\(session.workspaceName) · \(session.cwd)",
                        accent: session.phase == .interrupted ? .tronAmber : .tronPurple
                    )
                }
            }
        }
    }
}
