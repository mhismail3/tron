import Foundation
import Testing
@testable import TronMobile

@Suite("Read-only process transcript merge")
struct ReadOnlyProcessTranscriptMergeTests {
    @Test("canonical append retains loaded earlier prefix")
    func appendRetainsPrefix() throws {
        let existing = (0..<4).map(item)
        let refreshed = try ProcessTranscriptPage(
            items: (2..<6).map(item),
            start: 2,
            end: 6,
            total: 6,
            nextEntryId: nil,
            leafEntryId: "entry-5"
        )
        let result = ReadOnlyProcessTranscriptMerge.refreshing(
            existing: existing,
            existingStart: 0,
            existingTotal: 4,
            with: refreshed
        )
        #expect(result.items.map(\.id) == (0..<6).map { "entry-\($0)" })
        #expect(result.start == 0)
        #expect(result.total == 6)
        #expect(result.retainedLoadedPrefix)
    }

    @Test("page admission rejects empty duplicate and oversized item identities")
    func pageItemAdmission() {
        let valid = item(1)
        let empty: TranscriptItem = .message(MessageTranscriptItem(
            id: "", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
            kind: .message, role: .assistant,
            presentationId: "empty-presentation", content: []
        ))
        #expect(throws: (any Error).self) {
            _ = try ProcessTranscriptPage(
                items: [empty], start: 0, end: 1, total: 1,
                nextEntryId: nil, leafEntryId: nil
            )
        }
        #expect(throws: (any Error).self) {
            _ = try ProcessTranscriptPage(
                items: [valid, valid], start: 0, end: 2, total: 2,
                nextEntryId: nil, leafEntryId: nil
            )
        }
        let oversized = (0...SessionSnapshot.maximumTranscriptItems).map(item)
        #expect(throws: (any Error).self) {
            _ = try ProcessTranscriptPage(
                items: oversized, start: 0, end: oversized.count,
                total: oversized.count, nextEntryId: nil, leafEntryId: nil
            )
        }
    }

    @Test("branch replacement fails closed to the new canonical tail")
    func branchReplacementUsesNewTail() throws {
        let existing = (0..<4).map(item)
        let replacementItems = [item(20), item(21), item(22)]
        let refreshed = try ProcessTranscriptPage(
            items: replacementItems,
            start: 1,
            end: 4,
            total: 4,
            nextEntryId: nil,
            leafEntryId: "entry-22"
        )
        let result = ReadOnlyProcessTranscriptMerge.refreshing(
            existing: existing,
            existingStart: 0,
            existingTotal: 4,
            with: refreshed
        )
        #expect(result.items.map(\.id) == replacementItems.map(\.id))
        #expect(result.start == 1)
        #expect(!result.retainedLoadedPrefix)
    }

    private func item(_ index: Int) -> TranscriptItem {
        .message(MessageTranscriptItem(
            id: "entry-\(index)",
            parentId: index == 0 ? nil : "entry-\(index - 1)",
            timestamp: "2026-01-01T00:00:\(String(format: "%02d", index))Z",
            kind: .message,
            role: .assistant,
            presentationId: "presentation-\(index)",
            content: []
        ))
    }
}
