import SwiftUI

// MARK: - Session Fork Context

/// Context about the fork relationship for UI display
struct SessionForkContext {
    let parentSessionId: String
    let forkEventId: String  // The event we forked from (in parent session)
    let forkPointEventId: String  // The session.fork event in this session
    let parentSessionTitle: String?
    /// IDs of events that belong to the parent session (displayed differently)
    let parentEventIds: Set<String>
}

// MARK: - Sibling Branch Info

/// Information about a sibling branch (another session forked from the same event)
struct SiblingBranchInfo: Identifiable {
    let id: String  // sessionId
    let sessionTitle: String?
    let eventCount: Int
    let lastActivity: String
    var events: [SessionEvent]  // Loaded lazily on expand

    var displayTitle: String {
        sessionTitle ?? "Session \(id.prefix(8))"
    }
}

// MARK: - Session History ViewModel

/// ViewModel for managing session history tree state including sibling branches
@Observable
@MainActor
final class SessionHistoryViewModel {
    var events: [SessionEvent] = []
    var siblingBranches: [String: [SiblingBranchInfo]] = [:]  // keyed by fork point event ID
    var expandedBranchPoints: Set<String> = []
    var isLoading = true
    var forkContext: SessionForkContext?

    private let eventStoreManager: EventStoreManager
    private let rpcClient: RPCClient
    let sessionId: String

    init(sessionId: String, eventStoreManager: EventStoreManager, rpcClient: RPCClient) {
        self.sessionId = sessionId
        self.eventStoreManager = eventStoreManager
        self.rpcClient = rpcClient
    }

    var headEventId: String? {
        eventStoreManager.activeSession?.headEventId
    }

    func loadEvents() async {
        isLoading = true

        do {
            // First sync session events from server
            try await eventStoreManager.syncSessionEvents(sessionId: sessionId)

            // Check if this is a forked session
            let session = try? eventStoreManager.eventDB.sessions.get(sessionId)
            let isFork = session?.isFork == true

            if isFork, let rootEventId = session?.rootEventId {
                // For forked sessions, load the full ancestor chain
                events = try eventStoreManager.eventDB.events.getAncestors(rootEventId)

                // Also get any events after the root (children of root in this session)
                let sessionEvents = try eventStoreManager.getSessionEvents(sessionId)
                let rootIds = Set(events.map { $0.id })
                for event in sessionEvents where !rootIds.contains(event.id) {
                    events.append(event)
                }

                // Build fork context for UI display
                forkContext = buildForkContext(events: events, currentSessionId: sessionId)

                logger.info("Loaded forked session with \(events.count) events (including parent history)", category: .session)
            } else {
                // Regular session - just get session events
                events = try eventStoreManager.getSessionEvents(sessionId)
                forkContext = nil
            }

            // Find all branch points and load sibling info
            await loadSiblingBranches()
        } catch {
            logger.error("Failed to load events: \(error)", category: .session)
        }

        isLoading = false
    }

    /// Load sibling branch information for all fork points in the current tree
    private func loadSiblingBranches() async {
        // Find events that have children in other sessions (fork points)
        for event in events {
            do {
                let siblings = try eventStoreManager.eventDB.sessions.getSiblings(
                    forEventId: event.id,
                    excluding: sessionId
                )

                if !siblings.isEmpty {
                    let branchInfos = siblings.map { session in
                        SiblingBranchInfo(
                            id: session.id,
                            sessionTitle: session.displayTitle,
                            eventCount: session.eventCount,
                            lastActivity: session.lastActivityAt,
                            events: []  // Load lazily
                        )
                    }
                    siblingBranches[event.id] = branchInfos
                }
            } catch {
                logger.warning("Failed to load siblings for event \(event.id): \(error)", category: .session)
            }
        }
    }

    /// Load events for a sibling branch when expanded
    func loadBranchEvents(forEventId eventId: String, branchSessionId: String) async {
        guard var branches = siblingBranches[eventId],
              let index = branches.firstIndex(where: { $0.id == branchSessionId }) else {
            return
        }

        do {
            let branchEvents = try eventStoreManager.getSessionEvents(branchSessionId)
            branches[index].events = branchEvents
            siblingBranches[eventId] = branches
        } catch {
            logger.warning("Failed to load branch events: \(error)", category: .session)
        }
    }

    func toggleBranchExpanded(eventId: String) {
        withAnimation(.tronStandard) {
            if expandedBranchPoints.contains(eventId) {
                expandedBranchPoints.remove(eventId)
            } else {
                expandedBranchPoints.insert(eventId)

                // Load events for all sibling branches at this point
                if let branches = siblingBranches[eventId] {
                    for branch in branches where branch.events.isEmpty {
                        Task {
                            await loadBranchEvents(forEventId: eventId, branchSessionId: branch.id)
                        }
                    }
                }
            }
        }
    }

    /// Build fork context from events to identify parent session events
    private func buildForkContext(events: [SessionEvent], currentSessionId: String) -> SessionForkContext? {
        // Find the session.fork event in this session
        let forkEvents = events.filter { event in
            event.eventType == .sessionFork && event.sessionId == currentSessionId
        }
        guard let forkEvent = forkEvents.first else {
            return nil
        }

        // Parse the fork payload to get parent info
        let payload = SessionForkPayload(from: forkEvent.payload)
        guard let parentSessionId = payload?.sourceSessionId,
              let forkEventId = payload?.sourceEventId else {
            return nil
        }

        // Get parent session title
        let parentSession = try? eventStoreManager.eventDB.sessions.get(parentSessionId)
        let parentTitle = parentSession?.displayTitle

        // Identify which events belong to parent session(s)
        let parentEvents = events.filter { event in
            event.sessionId != currentSessionId
        }
        let parentEventIds = Set(parentEvents.map { $0.id })

        return SessionForkContext(
            parentSessionId: parentSessionId,
            forkEventId: forkEventId,
            forkPointEventId: forkEvent.id,
            parentSessionTitle: parentTitle,
            parentEventIds: parentEventIds
        )
    }
}
