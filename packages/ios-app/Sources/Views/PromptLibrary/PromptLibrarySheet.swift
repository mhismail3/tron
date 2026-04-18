import SwiftUI

/// Root sheet for the Prompt Library — toggles between History and Snippets.
/// Selecting an entry invokes `onSelect(text)` and dismisses; the caller wires
/// that into the composer text field (see `InputBar`).
@available(iOS 26.0, *)
struct PromptLibrarySheet: View {
    let rpcClient: RPCClient
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state = PromptLibraryState()
    @State private var editingSnippet: PromptSnippet?
    @State private var isCreatingSnippet = false
    @State private var showClearHistoryAlert = false
    @State private var previewingItem: PromptHistoryItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TronSegmentedControl(
                    options: [
                        (label: "History", value: PromptLibraryState.Tab.history),
                        (label: "Snippets", value: PromptLibraryState.Tab.snippets)
                    ],
                    selection: $state.activeTab
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Group {
                    switch state.activeTab {
                    case .history:
                        PromptHistoryListView(
                            state: state,
                            rpcClient: rpcClient,
                            onSelect: { text in
                                onSelect(text)
                                dismiss()
                            },
                            onPreview: { item in previewingItem = item }
                        )
                    case .snippets:
                        PromptSnippetListView(
                            state: state,
                            rpcClient: rpcClient,
                            onSelect: { text in
                                onSelect(text)
                                dismiss()
                            },
                            onEdit: { snippet in editingSnippet = snippet }
                        )
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Prompt Library", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if state.activeTab == .history && !state.historyItems.isEmpty {
                        Button(role: .destructive) {
                            showClearHistoryAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronError)
                        }
                        .accessibilityLabel("Clear history")
                    }
                    if state.activeTab == .snippets {
                        Button {
                            isCreatingSnippet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronEmerald)
                        }
                        .accessibilityLabel("Add snippet")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            switch state.activeTab {
                            case .history:
                                await state.loadHistory(rpc: rpcClient, reset: true)
                            case .snippets:
                                await state.loadSnippets(rpc: rpcClient)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                    .accessibilityLabel("Reload")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .tronErrorAlert(message: $state.errorMessage)
            .alert("Clear all history?", isPresented: $showClearHistoryAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    Task { await state.clearHistory(rpc: rpcClient) }
                }
            } message: {
                Text("This permanently removes every entry in your prompt history.")
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .sheet(isPresented: $isCreatingSnippet) {
            SnippetEditorSheet(
                initialSnippet: nil,
                onSave: { name, text in
                    await state.createSnippet(name: name, text: text, rpc: rpcClient) != nil
                }
            )
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorSheet(
                initialSnippet: snippet,
                onSave: { name, text in
                    await state.updateSnippet(id: snippet.id, name: name, text: text, rpc: rpcClient)
                }
            )
        }
        .sheet(item: $previewingItem) { item in
            PromptPreviewSheet(text: item.text) {
                onSelect(item.text)
                previewingItem = nil
                dismiss()
            }
        }
        .task {
            await state.loadHistory(rpc: rpcClient, reset: true)
            await state.loadSnippets(rpc: rpcClient)
        }
    }
}
