import Foundation
import SQLite3

/// Repository for thinking-related queries.
/// Extracted from EventDatabase for single responsibility.
@MainActor
final class ThinkingRepository {

    private weak var transport: DatabaseTransport?
    private let eventRepository: EventRepository

    init(transport: DatabaseTransport, eventRepository: EventRepository) {
        self.transport = transport
        self.eventRepository = eventRepository
    }

    // MARK: - Query Operations

    /// Get thinking blocks for a session (preview data for listing)
    /// - Parameters:
    ///   - sessionId: The session to query
    ///   - previewOnly: If true, only returns preview data (for listing). If false, loads full content.
    /// - Returns: Array of ThinkingBlock objects for UI display
    func getEvents(sessionId: String, previewOnly: Bool = true) throws -> [ThinkingBlock] {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        // Query message.assistant events which contain thinking in content blocks
        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events
            WHERE session_id = ? AND type = 'message.assistant'
            ORDER BY sequence ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var blocks: [ThinkingBlock] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            do {
                let event = try parseEventRow(stmt, transport: transport)

                // Extract thinking from content blocks
                guard let contentArray = event.payload["content"]?.value as? [[String: Any]] else {
                    continue
                }

                // Find thinking block in content array
                for (blockIndex, block) in contentArray.enumerated() {
                    guard let blockType = block["type"] as? String,
                          blockType == "thinking",
                          let thinkingText = block["thinking"] as? String,
                          !thinkingText.isEmpty else {
                        continue
                    }

                    // Extract turn number from payload
                    let turnNumber = event.payload["turn"]?.value as? Int ?? 1

                    // Create preview (first 3 lines, max 120 chars)
                    let preview = extractThinkingPreview(from: thinkingText)

                    // Create block with composite ID (eventId:blockIndex) for lazy loading
                    let thinkingBlock = ThinkingBlock(
                        eventId: "\(event.id):\(blockIndex)",
                        turnNumber: turnNumber,
                        preview: preview,
                        characterCount: thinkingText.count,
                        model: event.payload["model"]?.value as? String,
                        timestamp: ISO8601DateFormatter().date(from: event.timestamp) ?? Date()
                    )
                    blocks.append(thinkingBlock)
                }
            } catch {
                logger.warning("Failed to parse assistant message for thinking: \(error.localizedDescription)", category: .session)
            }
        }

        return blocks
    }

    /// Get full thinking content for a specific event ID (for lazy loading in sheet)
    /// - Parameter eventId: Composite ID in format "eventId:blockIndex" or plain event ID
    /// - Returns: The full thinking content string, or nil if not found
    func getContent(eventId: String) throws -> String? {
        // Parse composite ID format: "eventId:blockIndex"
        let components = eventId.split(separator: ":")
        let actualEventId: String
        let blockIndex: Int

        if components.count >= 2,
           let lastComponent = components.last,
           let index = Int(lastComponent) {
            // Composite ID: everything except last component is the event ID
            actualEventId = components.dropLast().joined(separator: ":")
            blockIndex = index
        } else {
            // Plain event ID (legacy format)
            actualEventId = eventId
            blockIndex = 0
        }

        guard let event = try eventRepository.get(actualEventId) else {
            return nil
        }

        // Handle message.assistant events with thinking in content blocks
        if event.type == "message.assistant" {
            guard let contentArray = event.payload["content"]?.value as? [[String: Any]] else {
                return nil
            }

            // Find thinking block at the specified index
            var thinkingIndex = 0
            for block in contentArray {
                guard let blockType = block["type"] as? String,
                      blockType == "thinking",
                      let thinkingText = block["thinking"] as? String else {
                    continue
                }

                if thinkingIndex == blockIndex {
                    return thinkingText
                }
                thinkingIndex += 1
            }
            return nil
        }

        // Legacy: stream.thinking_complete events
        if event.type == "stream.thinking_complete" {
            return event.payload.string("content")
        }

        logger.warning("Event \(eventId) does not contain thinking content (type: \(event.type))", category: .session)
        return nil
    }

    // MARK: - Private Helpers

    /// Extract preview (first 3 lines, max 120 chars) from thinking content
    private func extractThinkingPreview(from content: String, maxLines: Int = 3) -> String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxLines)
        let preview = lines.joined(separator: " ")
        if preview.count > 120 {
            return String(preview.prefix(117)) + "..."
        }
        return preview
    }

    /// Parse an event row from SQL result
    private func parseEventRow(_ stmt: OpaquePointer?, transport: DatabaseTransport) throws -> SessionEvent {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let parentId = transport.getOptionalText(stmt, 1)
        let sessionId = String(cString: sqlite3_column_text(stmt, 2))
        let workspaceId = String(cString: sqlite3_column_text(stmt, 3))
        let type = String(cString: sqlite3_column_text(stmt, 4))
        let timestamp = String(cString: sqlite3_column_text(stmt, 5))
        let sequence = Int(sqlite3_column_int(stmt, 6))
        let payloadJson = String(cString: sqlite3_column_text(stmt, 7))

        let payload: [String: AnyCodable]
        if let data = payloadJson.data(using: .utf8) {
            do {
                payload = try JSONDecoder().decode([String: AnyCodable].self, from: data)
            } catch {
                logger.warning("Failed to decode event payload for id=\(id): \(error.localizedDescription)", category: .session)
                payload = [:]
            }
        } else {
            payload = [:]
        }

        return SessionEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: workspaceId,
            type: type,
            timestamp: timestamp,
            sequence: sequence,
            payload: payload
        )
    }
}
