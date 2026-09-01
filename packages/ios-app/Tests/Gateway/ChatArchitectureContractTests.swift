import Testing
@testable import TronMobile

@Suite("Chat authority and presentation contracts")
struct ChatArchitectureContractTests {
    @Test("transcript window admission accepts a valid append")
    func acceptsValidAppend() throws {
        var current = try SessionScenarioBuilder(seed: 9_401).openingTail(targetEncodedBytes: 8_192)
        current.transcriptStart = 0
        current.transcriptTotal = current.transcript.count
        let appended = try #require(
            SessionScenarioBuilder(seed: 9_402).historyPage(count: 1, longRowBytes: 8).first
        )
        var incoming = current
        incoming.transcript.append(appended)
        incoming.transcriptTotal = current.transcriptTotal! + 1

        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(
                current: current,
                incoming: incoming
            ) == .accepted
        )
    }

    @Test("a gap or conflicting overlap is rejected before authority replacement")
    func rejectsDiscontinuousWindow() throws {
        var current = try SessionScenarioBuilder(seed: 9_403).openingTail(targetEncodedBytes: 8_192)
        current.transcriptStart = 0
        current.transcriptTotal = current.transcript.count
        var gap = current
        gap.transcriptStart = (current.transcriptStart ?? 0) + current.transcript.count + 1
        gap.transcriptTotal = gap.transcriptStart! + gap.transcript.count
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: current, incoming: gap)
                == .rejected(.gap)
        )

        var conflict = current
        let replacement = try #require(
            SessionScenarioBuilder(seed: 9_404).historyPage(count: 1, longRowBytes: 8).first
        )
        conflict.transcript[0] = replacement
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: current, incoming: conflict)
                == .rejected(.conflictingOverlap)
        )

        var sparse = current
        sparse.transcript = []
        sparse.transcriptStart = current.transcript.count
        sparse.transcriptTotal = current.transcriptTotal
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: current, incoming: sparse)
                == .rejected(.gap)
        )
    }

    @Test("partially bounded or duplicate windows fail closed")
    func rejectsMalformedWindow() throws {
        var partial = try SessionScenarioBuilder(seed: 9_405).openingTail(targetEncodedBytes: 8_192)
        partial.transcriptStart = 0
        partial.transcriptTotal = nil
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: nil, incoming: partial)
                == .rejected(.missingBounds)
        )

        var duplicate = partial
        duplicate.transcriptTotal = duplicate.transcript.count
        duplicate.transcript.append(duplicate.transcript[0])
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: nil, incoming: duplicate)
                == .rejected(.duplicateOrEmptyID)
        )
    }

    @Test("presentation transition classification is deterministic and identity-scoped")
    func transitionClassification() throws {
        let snapshot = try SessionScenarioBuilder(seed: 9_406).openingTail(targetEncodedBytes: 8_192)
        let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
        let initial = ChatTranscriptPresentationTransition(
            previousTag: nil,
            nextTag: tag,
            previousRowIDs: [],
            nextRowIDs: ["one"]
        )
        #expect(initial.kind == .initial)

        let appended = ChatTranscriptPresentationTransition(
            previousTag: tag,
            nextTag: tag,
            previousRowIDs: ["one"],
            nextRowIDs: ["one", "two"]
        )
        #expect(appended.kind == .append)
        #expect(appended.retainedRowIDs == ["one"])

        var replacementSnapshot = snapshot
        replacementSnapshot.runtimeGeneration = "new-runtime"
        let replacementTag = ChatTranscriptProjectionTag(
            snapshot: replacementSnapshot,
            presentationGeneration: 1
        )
        let replacement = ChatTranscriptPresentationTransition(
            previousTag: tag,
            nextTag: replacementTag,
            previousRowIDs: ["one"],
            nextRowIDs: ["one"]
        )
        #expect(replacement.kind == .replacement)
    }

    @Test("missing presentation IDs never establish a live canonical successor")
    func missingPresentationIDsDoNotMatch() {
        #expect(!ChatLiveCanonicalIdentityPolicy.matches(
            streamingID: "streaming",
            streamingPresentationID: nil,
            canonicalID: "canonical",
            canonicalPresentationID: nil
        ))
        #expect(!ChatLiveCanonicalIdentityPolicy.matches(
            streamingID: "streaming",
            streamingPresentationID: "",
            canonicalID: "canonical",
            canonicalPresentationID: ""
        ))
        #expect(ChatLiveCanonicalIdentityPolicy.matches(
            streamingID: "streaming",
            streamingPresentationID: "handoff",
            canonicalID: "canonical",
            canonicalPresentationID: "handoff"
        ))
        #expect(ChatLiveCanonicalIdentityPolicy.matches(
            streamingID: "streaming",
            streamingPresentationID: nil,
            canonicalID: "streaming",
            canonicalPresentationID: nil
        ))
    }

    @Test("UIKit commit rejects duplicate row identities")
    func uikitCommitRejectsDuplicateRows() {
        let first = ChatUIKitTranscriptRow(id: "same", text: "one")!
        let second = ChatUIKitTranscriptRow(id: "same", text: "two")!
        #expect(ChatUIKitTranscriptCommit(version: 1, rows: [first, second]) == nil)
        #expect(ChatUIKitTranscriptCommit(version: 1, rows: [first]) != nil)
    }

    @MainActor
    @Test("blank viewport recovery terminates when the semantic anchor cannot materialize")
    func blankRecoveryIsBounded() {
        let controller = ChatUIKitChatViewController()
        controller.loadViewIfNeeded()
        controller.setIntent(.preserve(.init(rowID: "missing", topOffset: 0)))
        let row = ChatUIKitTranscriptRow(id: "one", text: "one")!
        let commit = ChatUIKitTranscriptCommit(version: 1, rows: [row])!
        let outcome = controller.apply(commit)
        #expect(outcome == .recovered(1))
        #expect(controller.viewportState.intent == .preserve(.init(rowID: "missing", topOffset: 0)))
    }
}
