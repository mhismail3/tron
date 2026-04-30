import SwiftUI

/// Sheet showing full thinking content with real-time streaming support.
///
/// When thinking is actively streaming, content updates live and auto-scrolls to the bottom.
/// When the user scrolls up, auto-scroll pauses until they return to the bottom.
/// When streaming has ended, displays the final content statically (scrolled to top).
@available(iOS 26.0, *)
struct ThinkingDetailSheet: View {
    let state: ThinkingDetailState
    @Environment(\.dismiss) private var dismiss
    @State private var sawStreaming: Bool = false

    private let bottomAnchorID = "thinking-bottom"
    private let topAnchorID = "thinking-top"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear
                            .frame(height: 0)
                            .id(topAnchorID)

                        let blocks = MarkdownBlockParser.parse(state.displayContent)
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block, textColor: .tronTextPrimary)
                        }
                        // Invisible anchor at the bottom for scroll tracking
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .interacting || newPhase == .tracking {
                        state.userDidScroll()
                    }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    return distanceFromBottom < 50
                } action: { _, isNearBottom in
                    if isNearBottom {
                        state.userReturnedToBottom()
                    }
                }
                .onChange(of: state.displayContent) { _, _ in
                    if state.shouldAutoScroll {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: state.isActivelyStreaming) { _, isStreaming in
                    if isStreaming {
                        sawStreaming = true
                    } else if sawStreaming {
                        // Auto-dismiss once the thinking stream ends, so the user is
                        // returned to the chat. Small delay lets the final tokens settle.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    if state.isActivelyStreaming {
                        sawStreaming = true
                        // Deferred to next run loop: ScrollViewReader proxy requires
                        // layout to complete before scrollTo works reliably on appear.
                        DispatchQueue.main.async {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        if state.showStreamingIndicator {
                            PulsingIcon(icon: .thinking, size: 12, color: .tronPurple)
                        }
                        Text("Thinking")
                            .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                            .foregroundStyle(.tronPurple)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
