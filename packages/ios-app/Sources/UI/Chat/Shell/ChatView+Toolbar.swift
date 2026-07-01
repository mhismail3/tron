import SwiftUI

// MARK: - Toolbar Configuration

extension ChatView {
    /// Leading overlay button (back button or sidebar toggle).
    @ViewBuilder
    var leadingTopBarButton: some View {
        if let onToggleSidebar = onToggleSidebar {
            // iPad - show sidebar toggle
            TronToolbarIconButton(
                systemImage: "sidebar.leading",
                accessibilityLabel: "Show sidebar",
                font: TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium),
                action: onToggleSidebar
            )
        } else {
            // iPhone - show back button
            TronToolbarIconButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Back",
                font: TronTypography.button
            ) {
                dismiss()
            }
        }
    }

    /// Top-bar title with optional fork icon.
    var topBarTitle: some View {
        HStack(alignment: .center, spacing: 6) {
            SessionTitleIcons(
                isFork: eventStoreManager.activeSession?.isFork == true
            )
            TypewriterText(
                text: eventStoreManager.activeSession?.displayTitle ?? "Chat",
                font: TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold),
                color: .tronEmerald
            )
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: 230)
        .opacity(toolbarTitleOpacity)
        .offset(y: toolbarTitleOffsetY)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.easeOut(duration: 0.4)) {
                toolbarTitleOpacity = 1
                toolbarTitleOffsetY = 0
            }
        }
        .animation(.smooth(duration: 0.25), value: eventStoreManager.activeSession?.isFork)
    }

    /// Trailing overlay buttons (browser button and menu).
    var trailingTopBarButtons: some View {
        HStack(spacing: 8) {
            // Live stream button — visible only when a Display stream is active.
            if viewModel.displayStreamState.isStreamActive {
                TronToolbarIconButton(
                    systemImage: "play.rectangle.fill",
                    accessibilityLabel: "Open display stream",
                    font: TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium)
                ) {
                    viewModel.displayStreamState.showStreamSheet = true
                }
            }
            TronToolbarIconButton(
                systemImage: "gearshape",
                accessibilityLabel: "Settings",
                font: TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium)
            ) {
                NotificationCenter.default.post(name: .chatMenuAction, object: ChatMenuAction.settings.rawValue)
            }
        }
        .frame(height: 44)
    }
}
