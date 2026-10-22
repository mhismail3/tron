#if HOSTED_TEST
import Foundation
import TronMobileCore

/// `-history-large` (#1691): Session History over 6,733 canonical entries, served
/// in the Gateway's real 100-entry cursor pages, so the shared feed's
/// auto-loading, position chip and scrolling are exercised at scale.
/// Synthetic values only; one minute apart, newest now.
enum HostedLargeHistory {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-history-large")
    static let total = 6_733
    static let pageSize = 100
    /// Every read, so a test can prove pages load on demand rather than all at once.
    nonisolated(unsafe) static var reads = 0

    static var leafID: String { id(total - 1) }

    static func id(_ ordinal: Int) -> String { "h-\(ordinal)" }

    private static let anchor = Date.now

    private static func node(_ ordinal: Int) -> SessionTreeNode {
        let kinds: [(kind: String, role: TranscriptItem.Role?, preview: String)] = [
            ("message", .user, "Regenerate the settings goldens and show me the before and after for entry \(ordinal + 1)."),
            ("message", .assistant, "Rebased onto origin/main and reran verify --changed. Only the settings-session goldens differ, from the new group cards."),
            ("message", .toolResult, "2,214 lines · TronSettingsRow, TronGlassSurfaceModifier, TronStatusPill"),
            ("bash", nil, "scripts/tron verify --changed — 3 suites, 41 tests passed in 2m 12s"),
            ("message", .assistant, "The glass cards read as one family once the kind tint is gone; the icon carries the kind on its own."),
            ("compaction", nil, "Compacted 1,912 messages: restructure plan, slice ownership, lock rules and the RuntimeSlot move."),
            ("modelChange", nil, "anthropic/claude-opus-5-5"),
        ]
        let shape = kinds[ordinal % kinds.count]
        let timestamp = anchor.addingTimeInterval(-Double(total - 1 - ordinal) * 60)
        return SessionTreeNode(
            id: id(ordinal), parentId: ordinal == 0 ? nil : id(ordinal - 1),
            timestamp: timestamp.formatted(.iso8601), kind: shape.kind,
            label: ordinal == total - 2 ? "golden review ready" : nil,
            preview: shape.preview, role: shape.role, depth: ordinal,
            childCount: ordinal == total - 7 ? 2 : 0, isCurrentPath: ordinal % 97 != 3)
    }

    /// The newest page, or the page strictly older than an `older` cursor.
    static func page(_ params: [String: JSONValue], runtime: String) throws -> JSONValue {
        reads += 1
        let cursor = try params["cursor"].map { try $0.decode(SessionHistoryCursor.self) }
        let top = cursor.map { $0.ordinal - 1 } ?? total - 1
        let bottom = max(0, top - pageSize + 1)
        let nodes = stride(from: top, through: bottom, by: -1).map(node)
        let older = bottom > 0 ? SessionHistoryCursor(ordinal: bottom, entryId: id(bottom), direction: "older") : nil
        let newer = top + 1 < total ? SessionHistoryCursor(ordinal: top, entryId: id(top), direction: "newer") : nil
        return try JSONValue.encode(SessionHistoryPage(runtimeGeneration: runtime, nodes: nodes, older: older,
                                                       newer: newer, totalEntries: total))
    }

    static func entry(_ params: [String: JSONValue], runtime: String) throws -> JSONValue {
        let entryID = params["entryId"]?.stringValue ?? leafID
        let ordinal = Int(entryID.dropFirst(2)) ?? total - 1
        let shape = node(ordinal)
        let text = shape.preview + "\n\nThe light and dark before and after are attached for review; nothing merges until the intended diff is approved."
        return try JSONValue.encode(SessionHistoryEntryPage(
            runtimeGeneration: runtime, entryId: entryID, text: text, offset: 0, nextOffset: nil, previousOffset: nil,
            totalCharacters: text.utf16.count,
            metadata: .object(["role": shape.role.map { .string($0.rawValue) } ?? .null, "timestamp": .string(shape.timestamp),
                               "type": .string(shape.kind)])))
    }
}
#endif
