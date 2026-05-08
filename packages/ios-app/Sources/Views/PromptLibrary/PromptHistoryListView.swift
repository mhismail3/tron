import SwiftUI

/// Searchable, paginated list of prompt history rows.
@available(iOS 26.0, *)
struct PromptHistoryListView: View {
    @Bindable var state: PromptLibraryState
    let engineClient: EngineClient
    let onSelect: (String) -> Void
    let onPreview: (PromptHistoryItem) -> Void

    var body: some View {
        Group {
            if state.isLoadingHistory && state.historyItems.isEmpty {
                ProgressView()
                    .tint(.tronEmerald)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.historyItems.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
    }

    private var listContent: some View {
        List {
            ForEach(state.historyItems) { item in
                PromptHistoryRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(item.text) }
                    .onLongPressGesture { onPreview(item) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await state.deleteHistory(id: item.id, rpc: engineClient) }
                        } label: { Label("Delete", systemImage: "trash") }
                        .tint(.tronError)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.tronEmerald.opacity(0.15))
                    .onAppear {
                        if item.id == state.historyItems.last?.id && state.historyHasMore {
                            Task { await state.loadMoreHistory(rpc: engineClient) }
                        }
                    }
            }

            if state.isLoadingMoreHistory {
                HStack {
                    Spacer()
                    ProgressView().tint(.tronEmerald)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: state.historySearch.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(TronTypography.sans(size: 36))
                .foregroundStyle(.tronEmerald.opacity(0.5))
            Text(state.historySearch.isEmpty ? "No history yet" : "No matches")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(state.historySearch.isEmpty
                 ? "Prompts you send will appear here."
                 : "No prompts match \"\(state.historySearch)\".")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
