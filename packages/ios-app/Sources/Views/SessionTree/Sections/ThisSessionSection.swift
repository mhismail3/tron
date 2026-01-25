import SwiftUI

// MARK: - This Session Section

/// Section showing events from the current session (after fork point)
struct ThisSessionSection: View {
    let events: [SessionEvent]
    let headEventId: String?
    let onFork: (String) -> Void

    var body: some View {
        SectionCard(title: "This Session", icon: "sparkles", accentColor: .tronPurple) {
            if events.isEmpty || (events.count == 1 && events.first?.eventType == .sessionFork) {
                // Empty state - just forked, no new messages
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(TronTypography.sans(size: TronTypography.sizeHero, weight: .light))
                        .foregroundStyle(.tronTextMuted.opacity(0.5))

                    Text("No new messages yet")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextMuted)

                    Text("Start chatting to build history")
                        .font(TronTypography.sans(size: TronTypography.sizeBody2))
                        .foregroundStyle(.tronTextMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(events) { event in
                        // Skip the fork event itself in display
                        if event.eventType != .sessionFork {
                            EventRow(
                                event: event,
                                isHead: event.id == headEventId,
                                showForkButton: event.id != headEventId,
                                onFork: { onFork(event.id) }
                            )
                            .id(event.id)
                        }
                    }
                }
            }
        }
    }
}
