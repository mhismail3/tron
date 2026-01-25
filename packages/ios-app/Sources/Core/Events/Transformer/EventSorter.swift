import Foundation

/// Event sorting utilities.
///
/// Provides generic sorting for any type conforming to `EventTransformable`,
/// eliminating duplicate sorting logic for RawEvent and SessionEvent.
enum EventSorter {

    /// Sort events by sequence number (primary), which is the authoritative order from the database.
    ///
    /// Sequence number is always reliable and represents the actual event order.
    /// Thinking blocks within message.assistant content are already in correct order
    /// and are handled by the interleaved content processor.
    ///
    /// - Parameter events: Events to sort
    /// - Returns: Events sorted by sequence, then by timestamp
    static func sortBySequence<E: EventTransformable>(_ events: [E]) -> [E] {
        events.sorted { a, b in
            // Primary sort: by sequence number (authoritative order)
            if a.sequence != b.sequence {
                return a.sequence < b.sequence
            }

            // Secondary sort: by timestamp (for events with same sequence, if any)
            let tsA = parseTimestamp(a.timestamp)
            let tsB = parseTimestamp(b.timestamp)
            return tsA < tsB
        }
    }

    /// Parse ISO 8601 timestamp string to Date.
    ///
    /// Handles both standard format and format with fractional seconds.
    ///
    /// - Parameter isoString: ISO 8601 timestamp string
    /// - Returns: Parsed Date, or current date if parsing fails
    static func parseTimestamp(_ isoString: String) -> Date {
        // Try with fractional seconds first (server events)
        let formatterWithFractions = ISO8601DateFormatter()
        formatterWithFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractions.date(from: isoString) {
            return date
        }

        // Fallback to standard format without fractional seconds (test data)
        let formatterStandard = ISO8601DateFormatter()
        formatterStandard.formatOptions = [.withInternetDateTime]
        return formatterStandard.date(from: isoString) ?? Date()
    }
}
