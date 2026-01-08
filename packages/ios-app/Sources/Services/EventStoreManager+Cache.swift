import Foundation

// MARK: - Turn Content Caching

extension EventStoreManager {

    /// Cache full turn content from agent.turn event
    func cacheTurnContent(sessionId: String, turnNumber: Int, messages: [[String: Any]]) {
        let now = Date()

        // Clean expired entries first
        cleanExpiredCacheEntries()

        // Enforce size limit
        if turnContentCache[sessionId] == nil && turnContentCache.count >= maxCachedSessions {
            if let oldest = turnContentCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                turnContentCache.removeValue(forKey: oldest)
                logger.debug("Removed oldest cache entry for session \(oldest) to stay within limit")
            }
        }

        // Store messages with timestamp
        turnContentCache[sessionId] = (messages, now)
        logger.info("Cached turn \(turnNumber) content for session \(sessionId): \(messages.count) messages")

        // Log content block types for debugging
        for (idx, msg) in messages.enumerated() {
            let role = msg["role"] as? String ?? "unknown"
            if let content = msg["content"] as? [[String: Any]] {
                let types = content.compactMap { $0["type"] as? String }
                logger.debug("  Message \(idx) (\(role)): \(types.joined(separator: ", "))")
            } else if let text = msg["content"] as? String {
                logger.debug("  Message \(idx) (\(role)): text (\(text.count) chars)")
            }
        }
    }

    /// Clean expired cache entries
    func cleanExpiredCacheEntries() {
        let now = Date()
        let expiredCount = turnContentCache.filter { now.timeIntervalSince($0.value.timestamp) > cacheExpiry }.count
        if expiredCount > 0 {
            turnContentCache = turnContentCache.filter { now.timeIntervalSince($0.value.timestamp) <= cacheExpiry }
            logger.debug("Cleaned \(expiredCount) expired cache entries")
        }
    }

    /// Get cached turn content for enriching server events
    func getCachedTurnContent(sessionId: String) -> [[String: Any]]? {
        guard let cached = turnContentCache[sessionId] else { return nil }
        // Check if expired
        if Date().timeIntervalSince(cached.timestamp) > cacheExpiry {
            turnContentCache.removeValue(forKey: sessionId)
            logger.debug("Cache entry for session \(sessionId) expired, removed")
            return nil
        }
        return cached.messages
    }

    /// Clear cached turn content after successful enrichment
    func clearCachedTurnContent(sessionId: String) {
        turnContentCache.removeValue(forKey: sessionId)
        logger.debug("Cleared turn content cache for session \(sessionId)")
    }

    /// Enrich server events with cached turn content
    func enrichEventsWithCachedContent(events: [SessionEvent], sessionId: String) throws -> [SessionEvent] {
        guard let cachedMessages = getCachedTurnContent(sessionId: sessionId) else {
            return events
        }

        var enrichedEvents = events
        var enrichedCount = 0

        // Build a lookup of cached content by role
        let cachedAssistantMessages = cachedMessages.filter { ($0["role"] as? String) == "assistant" }

        // Find message.assistant events that might need enrichment
        for (idx, event) in enrichedEvents.enumerated() {
            guard event.type == "message.assistant" else { continue }

            let hasToolBlocks = checkForToolBlocks(in: event.payload)

            if !hasToolBlocks {
                if let richContent = cachedAssistantMessages.last,
                   let contentBlocks = richContent["content"] as? [[String: Any]],
                   contentBlocks.contains(where: { ($0["type"] as? String) == "tool_use" }) {

                    var enrichedPayload = event.payload
                    enrichedPayload["content"] = AnyCodable(contentBlocks)

                    let enrichedEvent = SessionEvent(
                        id: event.id,
                        parentId: event.parentId,
                        sessionId: event.sessionId,
                        workspaceId: event.workspaceId,
                        type: event.type,
                        timestamp: event.timestamp,
                        sequence: event.sequence,
                        payload: enrichedPayload
                    )

                    enrichedEvents[idx] = enrichedEvent
                    enrichedCount += 1
                    logger.info("Enriched event \(event.id) with \(contentBlocks.count) content blocks")
                }
            }
        }

        if enrichedCount > 0 {
            logger.info("Enriched \(enrichedCount) events with cached tool content for session \(sessionId)")
            clearCachedTurnContent(sessionId: sessionId)
        }

        return enrichedEvents
    }

    /// Check if event payload has tool_use or tool_result blocks
    func checkForToolBlocks(in payload: [String: AnyCodable]) -> Bool {
        guard let content = payload["content"]?.value else { return false }

        if content is String { return false }

        if let blocks = content as? [[String: Any]] {
            return blocks.contains { block in
                let type = block["type"] as? String
                return type == "tool_use" || type == "tool_result"
            }
        }

        if let blocks = content as? [Any] {
            return blocks.contains { element in
                if let block = element as? [String: Any] {
                    let type = block["type"] as? String
                    return type == "tool_use" || type == "tool_result"
                }
                return false
            }
        }

        return false
    }
}
