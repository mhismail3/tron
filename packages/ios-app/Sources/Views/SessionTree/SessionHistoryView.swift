import SwiftUI

// MARK: - Session History View (Redesigned)

/// Clean, mobile-first session history with clear inherited/current separation.
@available(iOS 26.0, *)
struct SessionHistoryView: View {
    let events: [SessionEvent]
    let headEventId: String?
    let sessionId: String
    var forkContext: SessionForkContext?
    let onFork: (String) -> Void
    var isLoading: Bool = false

    @State private var isInheritedExpanded = false
    @State private var selectedEventId: String?

    // MARK: - Computed Properties

    /// Events sorted chronologically (oldest first)
    private var sortedEvents: [SessionEvent] {
        events.sorted { $0.timestamp < $1.timestamp }
    }

    /// Events from parent session(s) - the inherited history
    private var inheritedEvents: [SessionEvent] {
        guard let context = forkContext else { return [] }
        return sortedEvents.filter { context.parentEventIds.contains($0.id) }
    }

    /// Events from this session only
    private var thisSessionEvents: [SessionEvent] {
        sortedEvents.filter { $0.sessionId == sessionId }
    }

    /// The event where this session forked from (in parent)
    private var forkPointEvent: SessionEvent? {
        guard let context = forkContext else { return nil }
        return events.first { $0.id == context.forkEventId }
    }

    /// Filter out noise events for cleaner display
    private func isSignificantEvent(_ event: SessionEvent) -> Bool {
        switch event.eventType {
        case .sessionStart, .sessionFork, .messageUser, .messageAssistant, .toolCall, .toolResult:
            return true
        case .streamTurnStart, .streamTurnEnd, .compactBoundary, .streamTextDelta, .streamThinkingDelta, .streamThinkingComplete:
            return false  // Hide streaming noise
        default:
            return true
        }
    }

    // MARK: - Pre-computed Filtered Events (Performance Optimization)

    /// Significant events for linear session display - computed once
    private var significantEvents: [SessionEvent] {
        sortedEvents.filter { isSignificantEvent($0) }
    }

    /// Significant inherited events - computed once
    private var significantInheritedEvents: [SessionEvent] {
        inheritedEvents.filter { isSignificantEvent($0) }
    }

    /// Significant events from this session - computed once
    private var significantThisSessionEvents: [SessionEvent] {
        thisSessionEvents.filter { isSignificantEvent($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                LoadingHistoryView()
            } else if events.isEmpty {
                EmptyHistoryView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            // Forked session: show inherited + this session
                            if forkContext != nil {
                                ForkedSessionContent(proxy: proxy)
                            } else {
                                // Linear session: just show all events
                                LinearSessionContent(proxy: proxy)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    // MARK: - Forked Session Layout

    @ViewBuilder
    private func ForkedSessionContent(proxy: ScrollViewProxy) -> some View {
        // Inherited Section (collapsible)
        InheritedSection(
            events: significantInheritedEvents,
            forkPointEvent: forkPointEvent,
            isExpanded: $isInheritedExpanded,
            parentSessionId: forkContext?.parentSessionId,
            onFork: onFork
        )

        // This Session Section
        ThisSessionSection(
            events: significantThisSessionEvents,
            headEventId: headEventId,
            onFork: onFork
        )
        .onAppear {
            // Scroll to HEAD
            if let head = headEventId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation {
                        proxy.scrollTo(head, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Linear Session Layout

    @ViewBuilder
    private func LinearSessionContent(proxy: ScrollViewProxy) -> some View {
        SectionCard(title: "Session Timeline", icon: "clock", accentColor: .tronPurple) {
            LazyVStack(spacing: 2) {
                ForEach(significantEvents) { event in
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
        .onAppear {
            if let head = headEventId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation {
                        proxy.scrollTo(head, anchor: .center)
                    }
                }
            }
        }
    }
}
