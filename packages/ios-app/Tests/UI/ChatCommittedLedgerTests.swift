import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat committed ledger")
struct ChatCommittedLedgerTests {
    @Test("live streaming keeps the committed revision and row render identities unchanged")
    func streamingDoesNotReevaluateHistory() async throws {
        try await withTestWatchdog { @MainActor in
            var baseline = try SessionScenarioBuilder(seed: 9_501)
                .openingTail(targetEncodedBytes: 8_000)
            baseline.phase = .idle
            baseline.streaming = nil
            baseline.toolExecutions = []
            let store = ChatTranscriptPresentationStore()
            let baselineTag = ChatTranscriptProjectionTag(
                snapshot: baseline,
                presentationGeneration: 7
            )
            #expect(store.submit(snapshot: baseline, tag: baselineTag))
            let first = try await store.waitForInstall(of: baselineTag)
            let firstRows = committedRows(from: first)

            var latest = first
            for update in 1...6 {
                var streaming = baseline
                streaming.phase = .running
                streaming.eventSequence += update
                streaming.revision += update
                streaming.streaming = try message(id: "stream", text: "update-\(update)")
                let tag = ChatTranscriptProjectionTag(
                    snapshot: streaming,
                    presentationGeneration: 7
                )
                #expect(store.submit(snapshot: streaming, tag: tag))
                latest = try await store.waitForInstall(of: tag)

                #expect(latest.committedLedger.revision == first.committedLedger.revision)
                #expect(latest.committedLedger.items == first.committedLedger.items)
                #expect(!latest.liveRegion.items.isEmpty)
            }

            let changedHistoryRows = zip(firstRows, committedRows(from: latest))
                .filter { pair in pair.0 != pair.1 }
                .count
            #expect(changedHistoryRows == 0)
        }
    }

    @Test("canonical append and prepend advance the ledger exactly once")
    func canonicalMutationsAdvanceRevision() throws {
        let first = ChatTranscriptRenderItem.transcript(try message(id: "one", text: "one"))
        let second = ChatTranscriptRenderItem.transcript(try message(id: "two", text: "two"))
        let earlier = ChatTranscriptRenderItem.transcript(try message(id: "zero", text: "zero"))

        let initial = ChatCommittedLedger.reconcile(items: [first], previous: nil)
        let unchanged = ChatCommittedLedger.reconcile(items: [first], previous: initial)
        let appended = ChatCommittedLedger.reconcile(items: [first, second], previous: unchanged)
        let prepended = ChatCommittedLedger.reconcile(
            items: [earlier, first, second],
            previous: appended
        )

        #expect(initial.revision == 1)
        #expect(unchanged.revision == initial.revision)
        #expect(appended.revision == initial.revision + 1)
        #expect(prepended.revision == appended.revision + 1)
    }

    @Test("hidden thinking labels are scoped to thinking row preparation")
    func hiddenThinkingLabelIsRowScoped() throws {
        let content = ChatTranscriptRenderItem.transcript(try message(id: "content", text: "hello"))
        let thinkingItem = try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data("""
            {"id":"thinking","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"thinking:0","ordinal":0,"type":"thinking","text":"work"}]}
            """.utf8)
        )
        let thinking = ChatTranscriptRenderItem.transcript(thinkingItem)
        let prepared = ChatTextPreparationSnapshot.empty.withHiddenThinkingLabel("Reasoning")

        #expect(prepared.slice(for: content).hiddenThinkingLabel == nil)
        #expect(prepared.slice(for: thinking).hiddenThinkingLabel == "Reasoning")
    }

    @Test("foreground replacement reuses history while cold reopen rebuilds deterministically")
    func foregroundAndColdReopen() async throws {
        try await withTestWatchdog { @MainActor in
            var snapshot = try SessionScenarioBuilder(seed: 9_502)
                .openingTail(targetEncodedBytes: 8_000)
            snapshot.phase = .idle
            snapshot.streaming = nil
            snapshot.toolExecutions = []

            let retainedStore = ChatTranscriptPresentationStore()
            let initialTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 3
            )
            retainedStore.submit(snapshot: snapshot, tag: initialTag)
            let initial = try await retainedStore.waitForInstall(of: initialTag)

            snapshot.eventSequence += 1
            snapshot.revision += 1
            let foregroundTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 4,
                entranceSuppressionGeneration: 1
            )
            retainedStore.submit(snapshot: snapshot, tag: foregroundTag)
            let foreground = try await retainedStore.waitForInstall(of: foregroundTag)

            #expect(foreground.committedLedger.revision == initial.committedLedger.revision)
            #expect(foreground.committedLedger.items == initial.committedLedger.items)
            #expect(retainedStore.pendingEntranceIDs.isEmpty)

            let reopenedStore = ChatTranscriptPresentationStore()
            let reopenedTag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: 1,
                entranceSuppressionGeneration: 1
            )
            reopenedStore.submit(snapshot: snapshot, tag: reopenedTag)
            let reopened = try await reopenedStore.waitForInstall(of: reopenedTag)

            #expect(reopened.committedLedger.revision == 1)
            #expect(reopened.committedLedger.items == foreground.committedLedger.items)
            #expect(reopened.liveRegion.items == foreground.liveRegion.items)
            #expect(reopenedStore.pendingEntranceIDs.isEmpty)
        }
    }

    private func committedRows(
        from installed: InstalledChatTranscript
    ) -> [ChatTranscriptRenderRow] {
        installed.committedLedger.items.map { item in
            ChatTranscriptRenderRow(
                item: item,
                preparedText: installed.preparedText(for: item),
                installationTag: installed.tag,
                toolPayloadRevision: installed.toolPayloadRevision(for: item),
                resolveToolDetails: { _ in nil },
                recordEvaluation: {},
                recordToolChip: { _ in }
            )
        }
    }

    private func message(id: String, text: String) throws -> TranscriptItem {
        try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data("""
            {"id":"\(id)","parentId":null,"presentationId":"stream:\(id)","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"\(id):0","ordinal":0,"type":"text","text":"\(text)"}]}
            """.utf8)
        )
    }
}
