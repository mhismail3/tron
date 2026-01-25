import Foundation

/// Handles event deduplication with business rules.
/// - Prefers events with tool blocks (richer content)
/// - Prefers server events (evt_*) over local events (UUIDs)
final class EventDeduplicator {

    private let eventDB: EventDatabase

    init(eventDB: EventDatabase) {
        self.eventDB = eventDB
    }

    // MARK: - Public API

    /// Deduplicate events for a session.
    /// Returns the number of duplicates removed.
    @MainActor
    func deduplicateSession(_ sessionId: String) throws -> Int {
        let events = try eventDB.getEventsBySession(sessionId)
        let idsToDelete = findDuplicateIds(in: events)

        if !idsToDelete.isEmpty {
            try eventDB.deleteEvents(ids: idsToDelete)
            logger.info("Deduplicated session \(sessionId): removed \(idsToDelete.count) duplicate events", category: .session)
        }

        return idsToDelete.count
    }

    /// Deduplicate all sessions.
    /// Returns the total number of duplicates removed.
    @MainActor
    func deduplicateAllSessions() throws -> Int {
        var totalRemoved = 0
        let sessions = try eventDB.getAllSessions()

        for session in sessions {
            totalRemoved += try deduplicateSession(session.id)
        }

        return totalRemoved
    }

    // MARK: - Duplicate Detection

    /// Find duplicate event IDs to remove.
    /// Groups events by (type, content prefix) and determines which to delete.
    func findDuplicateIds(in events: [SessionEvent]) -> [String] {
        // Group events by (type, content prefix) to find duplicates
        var keyToEvents: [String: [SessionEvent]] = [:]

        for event in events {
            if event.type == "message.user" || event.type == "message.assistant" {
                let contentStr = ContentExtractor.extractTextForMatching(from: event.payload)
                let key = "\(event.type):\(String(contentStr.prefix(100)))"

                var group = keyToEvents[key] ?? []
                group.append(event)
                keyToEvents[key] = group
            }
        }

        // Find duplicate groups and determine which to delete
        var idsToDelete: [String] = []

        for (_, group) in keyToEvents {
            if group.count > 1 {
                idsToDelete.append(contentsOf: selectIdsToDelete(from: group))
            }
        }

        return idsToDelete
    }

    // MARK: - Selection Logic

    /// Select which event IDs to delete from a group of duplicates.
    /// Prefers keeping events with tool blocks, then server events.
    private func selectIdsToDelete(from group: [SessionEvent]) -> [String] {
        var idsToDelete: [String] = []

        // Categorize events by content richness
        let eventsWithTools = group.filter { ContentExtractor.hasToolBlocks(in: $0.payload) }
        let eventsWithoutTools = group.filter { !ContentExtractor.hasToolBlocks(in: $0.payload) }

        if !eventsWithTools.isEmpty {
            // Keep events with tool blocks, delete those without
            idsToDelete.append(contentsOf: eventsWithoutTools.map { $0.id })

            // Among events with tools, prefer server events
            if eventsWithTools.count > 1 {
                let serverWithTools = eventsWithTools.filter { $0.id.hasPrefix("evt_") }
                let localWithTools = eventsWithTools.filter { !$0.id.hasPrefix("evt_") }

                if !serverWithTools.isEmpty {
                    // Keep server events with tools, delete local ones with tools
                    idsToDelete.append(contentsOf: localWithTools.map { $0.id })
                } else {
                    // Keep first local with tools
                    idsToDelete.append(contentsOf: localWithTools.dropFirst().map { $0.id })
                }
            }
        } else {
            // No events with tools - prefer server events
            let serverEvents = group.filter { $0.id.hasPrefix("evt_") }
            let localEvents = group.filter { !$0.id.hasPrefix("evt_") }

            if !serverEvents.isEmpty {
                idsToDelete.append(contentsOf: localEvents.map { $0.id })
            } else {
                // Keep first local, delete others
                idsToDelete.append(contentsOf: localEvents.dropFirst().map { $0.id })
            }
        }

        return idsToDelete
    }
}
