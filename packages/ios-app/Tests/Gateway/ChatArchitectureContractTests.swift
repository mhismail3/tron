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

    @Test("an exact preceding window is admitted for prepend")
    func acceptsValidPrepend() throws {
        var current = try SessionScenarioBuilder(seed: 9_402).openingTail(targetEncodedBytes: 8_192)
        current.transcriptStart = 1
        current.transcriptTotal = current.transcript.count + 1
        var incoming = current
        incoming.transcript = [try #require(
            SessionScenarioBuilder(seed: 9_405).historyPage(count: 1, longRowBytes: 8).first
        )]
        incoming.transcriptStart = 0
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: current, incoming: incoming)
                == .accepted
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

    @Test("bounded and unbounded transitions fail closed, including empty preceding pages")
    func rejectsAmbiguousWindowTransitions() throws {
        var bounded = try SessionScenarioBuilder(seed: 9_407).openingTail(targetEncodedBytes: 8_192)
        bounded.transcriptStart = 0
        bounded.transcriptTotal = bounded.transcript.count
        var unbounded = bounded
        unbounded.transcriptStart = nil
        unbounded.transcriptTotal = nil
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: bounded, incoming: unbounded)
                == .rejected(.gap)
        )
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: unbounded, incoming: bounded)
                == .rejected(.gap)
        )
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(
                current: bounded,
                incoming: unbounded,
                allowsValidatedRebaseline: true
            ) == .accepted
        )

        var emptyPreceding = bounded
        emptyPreceding.transcript = []
        emptyPreceding.transcriptStart = 0
        #expect(
            SessionTranscriptWindowAdmissionPolicy.evaluate(current: bounded, incoming: emptyPreceding)
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

    @Test("UIKit row input retains shared Markdown block identities")
    func uikitRowRetainsMarkdownBlocks() throws {
        let document = MarkdownPresentation.Document(source: "# Heading\n\n> quote\n\n- item\n\n```swift\nlet value = 1\n```\n\na | b\n--|--\nc | d\n\n---")
        let row = try #require(ChatUIKitTranscriptRow(
            id: "assistant-1",
            text: document.source,
            markdownDocuments: [document],
            streaming: true
        ))
        #expect(row.markdownDocuments == [document])
        #expect(row.markdownDocuments[0].blocks.count == 6)
        #expect(row.streaming)
    }

    @MainActor
    @Test("UIKit presentation adaptation retains installed physical row payloads")
    func presentationAdapterRetainsPayloads() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 9_407).openingTail(targetEncodedBytes: 8_192)
        let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
        let store = ChatTranscriptPresentationStore()
        #expect(store.submit(snapshot: snapshot, tag: tag))
        let installed = try await store.waitForInstall(of: tag)
        let input = try #require(ChatUIKitPresentationAdapter.input(
            from: installed,
            version: 1
        ))
        #expect(input.rows.isEmpty == false)
        #expect(input.rows.allSatisfy { $0.content != nil })
    }

    @MainActor
    @Test("UIKit admission is monotonic and stale outcomes do not mutate state")
    func uikitAdmissionIsMonotonic() throws {
        let controller = ChatUIKitChatViewController()
        controller.loadViewIfNeeded()
        let row = ChatUIKitTranscriptRow(id: "one", text: "one")!
        #expect(controller.apply(.init(version: 4, rows: [row])!) == .applied(1))
        #expect(controller.apply(.init(version: 3, rows: [row])!) == .stale(3))
        #expect(controller.apply(.init(version: 4, rows: [row])!) == .stale(4))
        #expect(controller.viewportState.appliedVersion == 4)
    }

    @MainActor
    @Test("UIKit generation replacement adopts a lower version and rejects old completions")
    func uikitGenerationScopesVersionAdmission() throws {
        let controller = ChatUIKitChatViewController()
        controller.loadViewIfNeeded()
        let row = ChatUIKitTranscriptRow(id: "one", text: "one")!
        #expect(controller.apply(.init(generation: 4, version: 20, rows: [row])!) == .applied(1))
        #expect(controller.apply(.init(generation: 5, version: 1, rows: [row])!) == .applied(2))
        #expect(controller.viewportState.appliedGeneration == 5)
        #expect(controller.viewportState.appliedVersion == 1)
        #expect(controller.apply(.init(generation: 4, version: 21, rows: [row])!) == .stale(21))
        #expect(controller.viewportState.appliedGeneration == 5)
        #expect(controller.viewportState.appliedVersion == 1)
    }

    @Test("UIKit presentation versions remain stale within one generation")
    @MainActor
    func uikitSameGenerationVersionAdmission() throws {
        let controller = ChatUIKitChatViewController()
        controller.loadViewIfNeeded()
        let row = ChatUIKitTranscriptRow(id: "one", text: "one")!
        #expect(controller.apply(.init(generation: 2, version: 8, rows: [row])!) == .applied(1))
        #expect(controller.apply(.init(generation: 2, version: 7, rows: [row])!) == .stale(7))
        #expect(controller.apply(.init(generation: 2, version: 8, rows: [row])!) == .stale(8))
    }

    @Test("UIKit history is a projection affordance with one semantic action")
    func uikitHistoryProjection() {
        #expect(ChatUIKitHistoryState.available.isAffordanceVisible)
        #expect(ChatUIKitHistoryState.loading.isAffordanceVisible)
        #expect(ChatUIKitHistoryState.failed("offline").isAffordanceVisible)
        #expect(!ChatUIKitHistoryState.hidden.isAffordanceVisible)
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
