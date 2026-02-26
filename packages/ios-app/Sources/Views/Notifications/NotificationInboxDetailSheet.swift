import SwiftUI

/// Detail sheet for a notification from the inbox.
///
/// Reuses the visual pattern from `NotifyAppDetailSheet` (title, body, markdown
/// sheetContent via `MarkdownBlockParser` + `MarkdownBlockView`).
///
/// Toolbar buttons modeled after `ContextAuditView`:
/// - Leading: "Go to Session" (only for user sessions)
/// - Trailing: "Mark Read" (only when unread)
@available(iOS 26.0, *)
struct NotificationInboxDetailSheet: View {
    let notification: NotificationDTO
    let notificationStore: NotificationStore
    var onGoToSession: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("autoMarkNotificationsRead") private var autoMarkRead = true
    @State private var hasMarkedRead = false

    private var isRead: Bool {
        notification.isRead || hasMarkedRead
    }

    var body: some View {
        NavigationStack {
            contentView
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if notification.isUserSession {
                            Button {
                                onGoToSession?(notification.sessionId)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.right.circle")
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                    Text("Go to Session")
                                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                                }
                                .foregroundStyle(.tronEmerald)
                            }
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Image(systemName: "bell.badge.fill")
                            Text("Notification")
                                .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        }
                        .foregroundStyle(.tronEmerald)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if !isRead {
                            Button {
                                Task { await markRead() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle")
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                    Text("Mark Read")
                                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                                }
                                .foregroundStyle(.tronEmerald)
                            }
                        } else {
                            Button("Done") { dismiss() }
                                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                        }
                    }
                }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .task {
            if autoMarkRead && !notification.isRead {
                await markRead()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    Text(notification.title)
                        .font(TronTypography.mono(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)

                    Text(notification.body)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                        .foregroundStyle(.tronTextSecondary)

                    // Timestamp + session info
                    HStack(spacing: 8) {
                        Text(DateParser.relativeAbbreviated(notification.timestamp))
                            .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .regular))
                            .foregroundStyle(.tronTextMuted)

                        if let sessionTitle = notification.sessionTitle {
                            Text(sessionTitle)
                                .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .regular))
                                .foregroundStyle(.tronTextMuted)
                                .lineLimit(1)
                        }
                    }
                }

                // Sheet content (markdown)
                if let sheetContent = notification.sheetContent, !sheetContent.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(.tronSlate)
                            Text("Details")
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                                .foregroundStyle(.tronTextMuted)
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            let blocks = MarkdownBlockParser.parse(sheetContent)
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                MarkdownBlockView(block: block, textColor: .tronTextSecondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Actions

    private func markRead() async {
        let success = await notificationStore.markRead(eventId: notification.eventId)
        if success {
            hasMarkedRead = true
        }
    }
}
