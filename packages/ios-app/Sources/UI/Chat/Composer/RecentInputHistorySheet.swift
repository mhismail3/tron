import SwiftUI

@MainActor
enum RecentInputHistoryPresentation {
    nonisolated static let title = "Recent Inputs"
    nonisolated static let buttonAccessibilityLabel = "Show recent inputs"
    nonisolated static let buttonAccessibilityHint = "Choose a recent message to insert into the composer."
    nonisolated static let emptyTitle = "No recent inputs"
    nonisolated static let emptyMessage = "Messages you send from this device will appear here."
    nonisolated static let clearSystemImage = "trash"
    nonisolated static let clearAccessibilityLabel = "Clear recent inputs"
    nonisolated static let rowFontSize = TronTypography.sizeBody

    static func shouldShowButton(
        inputHistory: InputHistoryStore?,
        agentPhase: AgentPhase,
        readOnly: Bool
    ) -> Bool {
        guard !readOnly, agentPhase.isIdle else { return false }
        return inputHistory?.history.isEmpty == false
    }
}

struct RecentInputHistorySheet: View {
    let historyStore: InputHistoryStore
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.history.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: RecentInputHistoryPresentation.title, color: .tronEmerald)
                }
                if !historyStore.history.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            historyStore.clearHistory()
                        } label: {
                            Image(systemName: RecentInputHistoryPresentation.clearSystemImage)
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel(RecentInputHistoryPresentation.clearAccessibilityLabel)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private var historyList: some View {
        List {
            ForEach(historyStore.history, id: \.self) { input in
                Button {
                    onSelect(input)
                    dismiss()
                } label: {
                    Text(input)
                        .font(TronTypography.sans(size: RecentInputHistoryPresentation.rowFontSize))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert recent input")
                .accessibilityValue(input)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(TronTypography.sans(size: 36))
                .foregroundStyle(.tronEmerald.opacity(0.5))
            Text(RecentInputHistoryPresentation.emptyTitle)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(RecentInputHistoryPresentation.emptyMessage)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
