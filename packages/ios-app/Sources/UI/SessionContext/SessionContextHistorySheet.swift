import SwiftUI

struct SessionContextHistorySheet: View {
    let requests: [SessionContextRequestSummaryDTO]
    let models: [ModelInfo]
    let hasMore: Bool
    let loadMore: () async -> Void
    let select: (SessionContextRequestSummaryDTO) async -> Void

    @State private var isLoadingMore = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(requests) { request in
                        Button {
                            Task { await select(request) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: request.manifestAvailable
                                    ? "text.page.badge.magnifyingglass"
                                    : "clock.badge.exclamationmark")
                                    .foregroundStyle(request.manifestAvailable
                                        ? .tronEmerald
                                        : .tronAmber)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(SessionContextPresentation.modelDisplayName(
                                        request.model,
                                        models: models,
                                        fallback: "Model request"
                                    ))
                                        .font(TronTypography.sans(
                                            size: TronTypography.sizeBody,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(.tronTextPrimary)
                                    Text(
                                        "\(request.messageCount) messages · \(request.toolCount) tools · \(request.automaticContextCount) automatic"
                                    )
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextSecondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(request.turn.map { "Turn \($0)" } ?? "Legacy")
                                        .font(TronTypography.pillValue)
                                        .foregroundStyle(.tronEmerald)
                                    Text(WorkerConsolePresentation.timestamp(request.timestamp) ?? "")
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                        .foregroundStyle(.tronTextMuted)
                                }
                            }
                            .padding(13)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: true)
                    }

                    if hasMore {
                        Button {
                            isLoadingMore = true
                            Task {
                                await loadMore()
                                isLoadingMore = false
                            }
                        } label: {
                            if isLoadingMore {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label("Load earlier requests", systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingMore)
                        .padding(12)
                        .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Model Requests", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }
}
