import Foundation
import SwiftUI

@MainActor
enum RecentInputHistoryPresentation {
    nonisolated static let title = "Recent Inputs"
    nonisolated static let emptyTitle = "No recent inputs"
    nonisolated static let emptyMessage = "Messages you send from this device will appear here."
    nonisolated static let clearSystemImage = "trash"
    nonisolated static let clearAccessibilityLabel = "Clear recent inputs"
    nonisolated static let clearConfirmationTitle = "Clear recent inputs?"
    nonisolated static let clearConfirmationMessage = "This removes every recent input stored on this device."
    nonisolated static let clearConfirmationActionTitle = "Clear Recent Inputs"
    nonisolated static let rowFontSize = TronTypography.sizeBody
    nonisolated static let rowLineLimit = 1
    nonisolated static let rowVerticalInset: CGFloat = 5
    nonisolated static let rowHorizontalInset: CGFloat = 18

    nonisolated static func preview(for input: String) -> String {
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let firstLine = lines.first else { return "" }
        guard lines.count > 1 else { return firstLine }
        return firstLine.hasSuffix("…") ? firstLine : firstLine + "…"
    }

    static func shouldShowMenuAction(
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
    @State private var showClearConfirmation = false

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
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: RecentInputHistoryPresentation.title, color: .tronEmerald)
                }
                if !historyStore.history.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            showClearConfirmation = true
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
        .confirmationDialog(
            RecentInputHistoryPresentation.clearConfirmationTitle,
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(RecentInputHistoryPresentation.clearConfirmationActionTitle, role: .destructive) {
                historyStore.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RecentInputHistoryPresentation.clearConfirmationMessage)
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
                    Text(RecentInputHistoryPresentation.preview(for: input))
                        .font(TronTypography.sans(size: RecentInputHistoryPresentation.rowFontSize))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(RecentInputHistoryPresentation.rowLineLimit)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert recent input")
                .accessibilityValue(input)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(
                    top: RecentInputHistoryPresentation.rowVerticalInset,
                    leading: RecentInputHistoryPresentation.rowHorizontalInset,
                    bottom: RecentInputHistoryPresentation.rowVerticalInset,
                    trailing: RecentInputHistoryPresentation.rowHorizontalInset
                ))
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
