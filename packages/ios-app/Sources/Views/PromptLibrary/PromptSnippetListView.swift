import SwiftUI

/// List of user-authored prompt snippets. Tap selects text for composer
/// insertion; management lives in generated UI surfaces.
@available(iOS 26.0, *)
struct PromptSnippetListView: View {
    @Bindable var state: PromptLibraryState
    let onSelect: (String) -> Void

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
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.tronEmerald.opacity(0.15))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(TronTypography.sans(size: 36))
                .foregroundStyle(.tronEmerald.opacity(0.5))
            Text("No snippets yet")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text("Use Manage to create your first snippet.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
