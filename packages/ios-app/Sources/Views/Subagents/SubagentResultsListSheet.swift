import SwiftUI

/// Sheet listing multiple pending subagent results for batch review.
/// Shown when tapping a consolidated notification with 2+ results.
/// Each row opens the SubagentDetailSheet; "Send All" sends everything at once.
@available(iOS 26.0, *)
struct SubagentResultsListSheet: View {
    let pendingSubagents: [SubagentToolData]
    let subagentState: SubagentState
    let eventStoreManager: EventStoreManager
    let engineClient: EngineClient
    var onSendAll: (() -> Void)?
    var onSendIndividual: ((SubagentToolData) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSubagent: SubagentToolData?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    ForEach(pendingSubagents, id: \.subagentSessionId) { subagent in
                        Button {
                            selectedSubagent = subagent
                        } label: {
                            resultRow(subagent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Agent Results", color: .tronTextPrimary)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSendAll?()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Send All")
                                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            Image(systemName: "paperplane.fill")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        }
                        .foregroundStyle(.tronEmerald)
                    }
                }
            }
            .sheet(item: $selectedSubagent) { subagent in
                SubagentDetailSheet(
                    data: subagent,
                    subagentState: subagentState,
                    eventStoreManager: eventStoreManager,
                    engineClient: engineClient,
                    onSendResults: onSendIndividual
                )
            }
        }
        .presentationDragIndicator(.hidden)
    }

    @ViewBuilder
    private func resultRow(_ subagent: SubagentToolData) -> some View {
        HStack(spacing: 12) {
            Image(systemName: subagent.status == .failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(subagent.status == .failed ? .tronError : .tronSuccess)

            VStack(alignment: .leading, spacing: 2) {
                Text(subagent.status == .failed ? "Agent failed" : "Agent completed")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text(subagent.taskPreview)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
            }

            Spacer()

            if let duration = subagent.formattedDuration {
                Text(duration)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }

            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .glassEffect(
            .regular.tint((subagent.status == .failed ? Color.tronError : Color.tronSuccess).opacity(0.08)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

// MARK: - Identifiable conformance for sheet(item:)

extension SubagentToolData: Identifiable {
    var id: String { subagentSessionId }
}
