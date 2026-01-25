import Foundation

/// TTL-based cache for turn content used to enrich server events.
/// Server sync events may arrive with truncated tool content - this cache preserves
/// the full content from agent.turn events for enrichment during sync.
final class TurnContentCache {

    // MARK: - Types

    struct CacheEntry {
        let messages: [[String: Any]]
        let timestamp: Date
    }

    // MARK: - Properties

    private var cache: [String: CacheEntry] = [:]
    private let maxEntries: Int
    private let expiry: TimeInterval

    // MARK: - Initialization

    init(maxEntries: Int = 10, expiry: TimeInterval = 120) {
        self.maxEntries = maxEntries
        self.expiry = expiry
    }

    // MARK: - Cache Operations

    /// Store turn content for a session.
    /// - Parameters:
    ///   - sessionId: The session ID
    ///   - turnNumber: Turn number (for logging)
    ///   - messages: The full message content to cache
    func store(sessionId: String, turnNumber: Int, messages: [[String: Any]]) {
        let now = Date()

        // Clean expired entries first
        cleanExpired()

        // Enforce size limit by evicting oldest
        if cache[sessionId] == nil && cache.count >= maxEntries {
            if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                cache.removeValue(forKey: oldest)
                logger.debug("Evicted oldest cache entry for session \(oldest) to stay within limit")
            }
        }

        // Store messages with timestamp
        cache[sessionId] = CacheEntry(messages: messages, timestamp: now)
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

    /// Get cached turn content for a session.
    /// Returns nil if not found or expired.
    func get(sessionId: String) -> [[String: Any]]? {
        guard let entry = cache[sessionId] else { return nil }

        // Check if expired
        if Date().timeIntervalSince(entry.timestamp) > expiry {
            cache.removeValue(forKey: sessionId)
            logger.debug("Cache entry for session \(sessionId) expired, removed")
            return nil
        }

        return entry.messages
    }

    /// Clear cached turn content for a session.
    func clear(sessionId: String) {
        cache.removeValue(forKey: sessionId)
        logger.debug("Cleared turn content cache for session \(sessionId)")
    }

    /// Clean all expired cache entries.
    func cleanExpired() {
        let now = Date()
        let expiredKeys = cache.filter { now.timeIntervalSince($0.value.timestamp) > expiry }.map { $0.key }

        if !expiredKeys.isEmpty {
            for key in expiredKeys {
                cache.removeValue(forKey: key)
            }
            logger.debug("Cleaned \(expiredKeys.count) expired cache entries")
        }
    }

    // MARK: - Event Enrichment

    /// Enrich server events with cached turn content.
    /// Server events may have truncated tool content - this restores the full content.
    func enrichEvents(_ events: [SessionEvent], sessionId: String) -> [SessionEvent] {
        guard let cachedMessages = get(sessionId: sessionId) else {
            return events
        }

        var enrichedEvents = events
        var enrichedCount = 0

        // Build a lookup of cached assistant messages with tool blocks
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
            clear(sessionId: sessionId)
        }

        return enrichedEvents
    }

    /// Check if event payload has tool_use or tool_result blocks.
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
