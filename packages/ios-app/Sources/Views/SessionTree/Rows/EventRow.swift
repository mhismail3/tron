import SwiftUI

// MARK: - Event Row

/// Row display for session events in the history list view
struct EventRow: View {
    let event: SessionEvent
    var isHead: Bool = false
    var isMuted: Bool = false
    var showForkButton: Bool = true
    let onFork: () -> Void

    @State private var isExpanded = false

    /// Whether this event has expandable content to show
    private var hasExpandableContent: Bool {
        event.expandedContent != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - tappable to expand
            HStack(spacing: 10) {
                // Icon
                eventIcon
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(isMuted ? iconColor.opacity(0.5) : iconColor)
                    .frame(width: 20)

                // Summary + expand indicator
                Text(event.summary)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(isMuted ? .tronTextMuted : .tronTextPrimary)
                    .lineLimit(1)

                // Expand indicator (if has content) - placed next to event name
                if hasExpandableContent {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }

                Spacer()

                // HEAD badge
                if isHead {
                    Text("HEAD")
                        .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .bold))
                        .foregroundStyle(.tronTextPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronPurple)
                        .clipShape(Capsule())
                }

                // Fork button with circular background
                if showForkButton {
                    Button(action: onFork) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronPurple)
                            .frame(width: 28, height: 28)
                            .background(Color.tronPurple.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isHead ? Color.tronPurple.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                if hasExpandableContent {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded content
            if isExpanded, let content = event.expandedContent {
                Text(content)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2))
                    .foregroundStyle(isMuted ? .tronTextMuted : .tronTextSecondary)
                    .lineLimit(12)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tronSurfaceElevated.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private var eventIcon: some View {
        EventIconProvider.icon(for: event)
    }

    private var iconColor: Color {
        EventIconProvider.color(for: event.eventType, payload: event.payload)
    }
}
