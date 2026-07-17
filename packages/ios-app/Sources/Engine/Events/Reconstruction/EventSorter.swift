import Foundation

/// Event sorting utilities.
///
/// Provides generic sorting for any type conforming to `EventTransformable`,
/// eliminating duplicate sorting logic for RawEvent and SessionEvent.
enum EventSorter {

    /// Sort events within one session by its sequence number.
    ///
    /// Sequence is authoritative only inside one session. Fork reconstruction
    /// crosses independent parent/child sequence domains and must preserve the
    /// server-authored ancestor-chain order instead of calling this helper.
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
        DateParser.parseOrNow(isoString)
    }
}
