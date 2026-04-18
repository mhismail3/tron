import SwiftUI

/// List of user-authored prompt snippets. Tap selects; swipe exposes
/// edit/delete actions.
@available(iOS 26.0, *)
struct PromptSnippetListView: View {
    @Bindable var state: PromptLibraryState
    let rpcClient: RPCClient
    let onSelect: (String) -> Void
    let onEdit: (PromptSnippet) -> Void

    var body: some View {
        Group {
            if state.isLoadingSnippets && state.snippets.isEmpty {
                ProgressView()
                    .tint(.tronEmerald)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.snippets.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
    }

    private var listContent: some View {
        List {
            ForEach(state.snippets) { snippet in
                PromptSnippetRow(snippet: snippet)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(snippet.text) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await state.deleteSnippet(id: snippet.id, rpc: rpcClient) }
                        } label: { Label("Delete", systemImage: "trash") }
                        .tint(.tronError)

                        Button {
                            onEdit(snippet)
                        } label: { Label("Edit", systemImage: "pencil") }
                        .tint(.tronEmerald)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.tronEmerald.opacity(0.15))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await state.loadSnippets(rpc: rpcClient)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(TronTypography.sans(size: 36))
                .foregroundStyle(.tronEmerald.opacity(0.5))
            Text("No snippets yet")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text("Tap + to create your first snippet.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
