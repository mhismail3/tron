import SwiftUI

/// Sheet showing full thinking content with history
/// Supports lazy loading: only loads full content when a block is tapped
@available(iOS 26.0, *)
struct ThinkingDetailSheet: View {
    @Bindable var thinkingState: ThinkingState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Current streaming section (if active)
                    if thinkingState.isStreaming && !thinkingState.currentText.isEmpty {
                        CurrentThinkingSection(text: thinkingState.currentText)
                    }

                    // History blocks (reverse order - newest first)
                    if !thinkingState.blocks.isEmpty {
                        Section {
                            ForEach(thinkingState.blocks.reversed()) { block in
                                ThinkingBlockCard(
                                    block: block,
                                    isSelected: thinkingState.isBlockSelected(block.id),
                                    loadedContent: thinkingState.loadedFullContent,
                                    isLoading: thinkingState.isLoadingContent && thinkingState.selectedBlockId == block.id
                                ) {
                                    Task {
                                        await thinkingState.loadFullContent(blockId: block.id)
                                    }
                                }
                            }
                        } header: {
                            SectionHeader(title: "History", count: thinkingState.blocks.count)
                        }
                    }

                    // Empty state
                    if !thinkingState.isStreaming && thinkingState.blocks.isEmpty {
                        EmptyThinkingView()
                    }
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            .navigationTitle("Thinking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.tronEmerald)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Current Thinking Section

private struct CurrentThinkingSection: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with live indicator
            HStack(spacing: 6) {
                RotatingIcon(icon: .thinking, size: 14, color: .tronPurple)
                Text("Currently Thinking")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronPurple)
                Spacer()
                // Character count
                Text("\(text.count) chars")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronTextMuted)
            }

            // Full content (scrollable within the card if needed)
            Text(text)
                .font(TronTypography.messageBody)
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
        }
        .padding()
        .background(Color.tronPurple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronPurple.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Thinking Block Card

private struct ThinkingBlockCard: View {
    let block: ThinkingBlock
    let isSelected: Bool
    let loadedContent: String
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Header: Turn N - Model - Timestamp
                HStack(spacing: 6) {
                    Text("Turn \(block.turnNumber)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextSecondary)

                    if let model = block.shortModelName {
                        Text("-")
                            .foregroundStyle(.tronTextMuted)
                        Text(model)
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    Text(block.formattedTimestamp)
                        .font(TronTypography.pillValue)
                        .foregroundStyle(.tronTextMuted)
                }

                // Content: preview or full (if selected)
                if isSelected {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading...")
                                .font(TronTypography.caption)
                                .foregroundStyle(.tronTextMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                    } else {
                        Text(loadedContent)
                            .font(TronTypography.messageBody)
                            .foregroundStyle(.tronTextPrimary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(block.preview)
                        .font(TronTypography.messageBody)
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(3)
                }

                // Footer: expand indicator when collapsed
                if !isSelected {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(TronTypography.sans(size: 10, weight: .medium))
                        Text("\(block.characterCount) characters - Tap to expand")
                            .font(TronTypography.pillValue)
                    }
                    .foregroundStyle(.tronPurple.opacity(0.8))
                }
            }
            .padding()
            .background(isSelected ? Color.tronSurface.opacity(0.8) : Color.tronSurface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.tronPurple.opacity(0.4) : Color.tronBorder.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
            Text("(\(count))")
                .font(TronTypography.caption)
                .foregroundStyle(.tronTextMuted)
            Spacer()
        }
        .padding(.top, 8)
    }
}

// MARK: - Empty State

private struct EmptyThinkingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundStyle(.tronTextMuted)
            Text("No Thinking History")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
            Text("Extended thinking content will appear here when using models that support it.")
                .font(TronTypography.caption)
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Fallback for iOS 17

struct ThinkingDetailSheetFallback: View {
    @Bindable var thinkingState: ThinkingState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if thinkingState.isStreaming && !thinkingState.currentText.isEmpty {
                        CurrentThinkingSection(text: thinkingState.currentText)
                    }

                    if !thinkingState.blocks.isEmpty {
                        ForEach(thinkingState.blocks.reversed()) { block in
                            ThinkingBlockCard(
                                block: block,
                                isSelected: thinkingState.isBlockSelected(block.id),
                                loadedContent: thinkingState.loadedFullContent,
                                isLoading: thinkingState.isLoadingContent && thinkingState.selectedBlockId == block.id
                            ) {
                                Task {
                                    await thinkingState.loadFullContent(blockId: block.id)
                                }
                            }
                        }
                    }

                    if !thinkingState.isStreaming && thinkingState.blocks.isEmpty {
                        EmptyThinkingView()
                    }
                }
                .padding()
            }
            .background(Color.tronBackground)
            .navigationTitle("Thinking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.tronEmerald)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
