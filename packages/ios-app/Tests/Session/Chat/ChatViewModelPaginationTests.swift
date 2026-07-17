import XCTest
@testable import TronMobile

@MainActor
final class ChatViewModelPaginationTests: XCTestCase {

    func testTopDetentAutoloadLoadsFromPrunedBufferFirst() async {
        let (viewModel, _) = makeViewModel()
        populateMessages(viewModel, count: 250)
        viewModel.pruneOldMessagesIfNeeded()

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, ChatViewModel.additionalMessageBatchSize)
        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget + ChatViewModel.additionalMessageBatchSize)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 150 - ChatViewModel.additionalMessageBatchSize)
    }

    func testTopDetentAutoloadContinuesToServerAfterPrunedBufferDrains() async {
        let (viewModel, sessions) = makeViewModel()
        populateMessages(viewModel, count: 210)
        viewModel.reconstructionOldestEventId = "cursor-1"
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.hasMoreMessages = true
        viewModel.pruneOldMessagesIfNeeded()

        sessions.reconstructHandler = { _, _, beforeEventId in
            XCTAssertEqual(beforeEventId, "cursor-1")
            return self.reconstructResult(
                events: [self.rawEvent(id: "event-user-1", type: "message.user", content: "older prompt", sequence: 1)],
                hasMoreEvents: false,
                oldestEventId: "cursor-0"
            )
        }

        var prunedLoads: [Int] = []
        while !viewModel.prunedLiveMessages.isEmpty {
            prunedLoads.append(await viewModel.loadEarlierMessagesForTopDetent())
        }
        let serverLoad = await viewModel.loadEarlierMessagesForTopDetent()

        let batchSize = ChatViewModel.additionalMessageBatchSize
        XCTAssertEqual(prunedLoads, expectedDrainLoads(total: 110, batchSize: batchSize))
        XCTAssertEqual(serverLoad, 1)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-1"])
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "cursor-0")
        XCTAssertFalse(viewModel.hasMoreMessages)
    }

    func testTopDetentAutoloadLoadsHiddenReconstructedRowsAfterPrunedLiveBufferDrains() async {
        let (viewModel, sessions) = makeViewModel()
        let reconstructed = (0..<80).map { index in
            makeMessage("history \(index)")
        }
        viewModel.allReconstructedMessages = reconstructed
        viewModel.replaceAllMessages(with: Array(reconstructed.suffix(40)))
        viewModel.displayedMessageCount = 40

        for index in 0..<170 {
            viewModel.appendToMessages(makeMessage("live \(index)"))
        }

        viewModel.reconstructionOldestEventId = "cursor-history"
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.recomputeHasMoreMessages()
        viewModel.pruneOldMessagesIfNeeded()

        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 110)
        XCTAssertEqual(viewModel.displayedMessageCount, 40)

        var prunedLoads: [Int] = []
        while !viewModel.prunedLiveMessages.isEmpty {
            prunedLoads.append(await viewModel.loadEarlierMessagesForTopDetent())
        }
        let inMemoryLoad = await viewModel.loadEarlierMessagesForTopDetent()

        let batchSize = ChatViewModel.additionalMessageBatchSize
        XCTAssertEqual(prunedLoads, expectedDrainLoads(total: 110, batchSize: batchSize))
        XCTAssertEqual(inMemoryLoad, min(ChatViewModel.additionalMessageBatchSize, 40))
        XCTAssertEqual(sessions.reconstructCalls.count, 0)
        XCTAssertEqual(viewModel.messages.first?.id, reconstructed.first?.id)
        XCTAssertTrue(viewModel.hasMoreMessages)
    }

    func testTopDetentAutoloadLoadsFromInMemoryReconstruction() async {
        let (viewModel, _) = makeViewModel()
        let reconstructed = (0..<150).map { index in
            makeMessage("history \(index)")
        }
        viewModel.allReconstructedMessages = reconstructed
        viewModel.replaceAllMessages(with: Array(reconstructed.suffix(50)))
        viewModel.displayedMessageCount = 50
        viewModel.hasMoreMessages = true

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        let expectedLoad = min(ChatViewModel.additionalMessageBatchSize, 100)
        XCTAssertEqual(loaded, expectedLoad)
        XCTAssertEqual(viewModel.messages.count, 50 + expectedLoad)
        XCTAssertEqual(viewModel.messages.first?.id, reconstructed[150 - 50 - expectedLoad].id)
    }

    func testTopDetentAutoloadDuplicateLoadGuard() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.isLoadingMoreMessages = true

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 0)
        XCTAssertEqual(sessions.reconstructCalls.count, 0)
    }

    func testTopDetentAutoloadAdvancesPastEmptyServerPages() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.reconstructionOldestEventId = "cursor-2"

        sessions.reconstructHandler = { _, _, beforeEventId in
            if beforeEventId == "cursor-2" {
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-1")
            }
            return self.reconstructResult(
                events: [self.rawEvent(id: "event-user-1", type: "message.user", content: "older prompt", sequence: 1)],
                hasMoreEvents: false,
                oldestEventId: "cursor-0"
            )
        }

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 1)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-2", "cursor-1"])
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "cursor-0")
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertEqual(viewModel.messages.count, 1)
    }

    func testTopDetentAutoloadEmptyServerPageLimitStopsAdvertisingMoreHistory() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.reconstructionOldestEventId = "cursor-3"

        sessions.reconstructHandler = { _, _, beforeEventId in
            switch beforeEventId {
            case "cursor-3":
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-2")
            case "cursor-2":
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-1")
            case "cursor-1":
                return self.reconstructResult(events: [], hasMoreEvents: true, oldestEventId: "cursor-0")
            default:
                XCTFail("Unexpected cursor: \(String(describing: beforeEventId))")
                return self.reconstructResult(events: [], hasMoreEvents: false, oldestEventId: nil)
            }
        }

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 0)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-3", "cursor-2", "cursor-1"])
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "cursor-0")
        XCTAssertFalse(viewModel.hasOlderServerReconstructionPages)
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testTopDetentAutoloadServerErrorEmitsDedupedLocalError() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.reconstructionOldestEventId = "cursor-1"
        sessions.reconstructHandler = { _, _, _ in
            throw EngineConnectionError.invalidResponse
        }

        let firstLoaded = await viewModel.loadEarlierMessagesForTopDetent()
        let secondLoaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(firstLoaded, 0)
        XCTAssertEqual(secondLoaded, 0)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-1"])
        XCTAssertFalse(viewModel.hasOlderServerReconstructionPages)
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertEqual(viewModel.localNotificationIdsByDedupKey.keys.filter { $0 == "session.loadEarlier.failed" }.count, 1)
        let localErrorCount = viewModel.messages.filter {
            if case .localNotification = $0.content { return true }
            return false
        }.count
        XCTAssertEqual(localErrorCount, 1)
    }

    func testContextAwareServerPageKeepsCompletedCapabilityChip() async {
        let (viewModel, sessions) = makeViewModel()
        viewModel.hasMoreMessages = true
        viewModel.reconstructionOldestEventId = "cursor-1"
        viewModel.loadedReconstructionEvents = [
            rawCapabilityCompleted(id: "event-completed", invocationId: "capability-1", sequence: 3)
        ]

        sessions.reconstructHandler = { _, _, _ in
            self.reconstructResult(
                events: [
                    self.rawCapabilityStarted(id: "event-started", invocationId: "capability-1", sequence: 1),
                    self.rawAssistantWithCapability(id: "event-assistant", invocationId: "capability-1", sequence: 2)
                ],
                hasMoreEvents: false,
                oldestEventId: "cursor-0"
            )
        }

        let loaded = await viewModel.loadEarlierMessagesForTopDetent()

        XCTAssertEqual(loaded, 1)
        guard case .capabilityInvocation(let invocation) = viewModel.messages.first?.content else {
            return XCTFail("Expected reconstructed capability chip")
        }
        XCTAssertEqual(invocation.id, "capability-1")
        XCTAssertEqual(invocation.status, .success)
        XCTAssertEqual(invocation.result, "done")
    }

    func testReconnectReconstructionPreservesExpandedVisibleWindow() async {
        let (viewModel, _) = makeViewModel()
        let previousEvents = rawMessageEvents(range: 1...180)
        viewModel.loadedReconstructionEvents = previousEvents
        viewModel.allReconstructedMessages = UnifiedEventTransformer.transformPersistedEvents(previousEvents, presorted: true)
        viewModel.replaceAllMessages(with: Array(viewModel.allReconstructedMessages.suffix(150)))
        viewModel.displayedMessageCount = 150
        viewModel.hasInitiallyLoaded = true
        viewModel.hasOlderServerReconstructionPages = false

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: rawMessageEvents(range: 131...200),
                hasMoreEvents: true,
                oldestEventId: "event-131"
            )
        )

        XCTAssertEqual(viewModel.loadedReconstructionEvents.count, 200)
        XCTAssertEqual(viewModel.allReconstructedMessages.count, 200)
        XCTAssertEqual(viewModel.displayedMessageCount, 200)
        XCTAssertEqual(viewModel.messages.count, 200)
        XCTAssertFalse(viewModel.hasOlderServerReconstructionPages)
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertEqual(textContent(viewModel.messages.first), "message 1")
    }

    func testReconnectReconstructionBackfillsGapBeforeRebuildingMessages() async {
        let (viewModel, sessions) = makeViewModel()
        let previousEvents = rawMessageEvents(range: 1...100)
        viewModel.loadedReconstructionEvents = previousEvents
        viewModel.allReconstructedMessages = UnifiedEventTransformer.transformPersistedEvents(previousEvents, presorted: true)
        viewModel.replaceAllMessages(with: viewModel.allReconstructedMessages)
        viewModel.displayedMessageCount = 100
        viewModel.hasInitiallyLoaded = true
        viewModel.hasOlderServerReconstructionPages = false

        sessions.reconstructHandler = { _, _, beforeEventId in
            XCTAssertEqual(beforeEventId, "event-181")
            return self.reconstructResult(
                events: self.rawMessageEvents(range: 101...180),
                hasMoreEvents: true,
                oldestEventId: "event-101"
            )
        }

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: rawMessageEvents(range: 181...200),
                hasMoreEvents: true,
                oldestEventId: "event-181"
            )
        )

        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["event-181"])
        XCTAssertEqual(viewModel.loadedReconstructionEvents.count, 200)
        XCTAssertEqual(viewModel.allReconstructedMessages.count, 200)
        XCTAssertEqual(viewModel.displayedMessageCount, 200)
        XCTAssertEqual(viewModel.messages.count, 200)
        XCTAssertFalse(viewModel.hasOlderServerReconstructionPages)
        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertEqual(textContent(viewModel.messages.first), "message 1")
        XCTAssertEqual(textContent(viewModel.messages.last), "message 200")
    }

    func testReconnectExpandedWindowTrustsServerPaginationExhaustion() async {
        let (viewModel, _) = makeViewModel()
        let previousEvents = rawMessageEvents(range: 101...350)
        viewModel.loadedReconstructionEvents = previousEvents
        viewModel.allReconstructedMessages = UnifiedEventTransformer.transformPersistedEvents(
            previousEvents,
            presorted: true
        )
        viewModel.replaceAllMessages(with: Array(viewModel.allReconstructedMessages.suffix(100)))
        viewModel.displayedMessageCount = 100
        viewModel.hasInitiallyLoaded = true
        viewModel.reconstructionOldestEventId = "event-101"
        viewModel.hasOlderServerReconstructionPages = true

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: rawMessageEvents(range: 1...350),
                hasMoreEvents: false,
                oldestEventId: "event-1"
            )
        )

        XCTAssertEqual(viewModel.loadedReconstructionEvents.map(\.id), (1...350).map { "event-\($0)" })
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "event-1")
        XCTAssertFalse(viewModel.hasOlderServerReconstructionPages)
    }

    func testReconnectGapFailureReplacesDisjointCacheAndKeepsRecoveryCursor() async {
        let (viewModel, sessions) = makeViewModel()
        let previousEvents = rawMessageEvents(range: 1...100)
        viewModel.loadedReconstructionEvents = previousEvents
        viewModel.allReconstructedMessages = UnifiedEventTransformer.transformPersistedEvents(
            previousEvents,
            presorted: true
        )
        viewModel.replaceAllMessages(with: viewModel.allReconstructedMessages)
        viewModel.displayedMessageCount = 100
        viewModel.hasInitiallyLoaded = true
        viewModel.hasOlderServerReconstructionPages = false
        sessions.reconstructHandler = { _, _, _ in
            throw EngineConnectionError.invalidResponse
        }

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: rawMessageEvents(range: 181...200),
                hasMoreEvents: true,
                oldestEventId: "event-181"
            )
        )

        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["event-181"])
        XCTAssertEqual(viewModel.loadedReconstructionEvents.map(\.id), (181...200).map { "event-\($0)" })
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "event-181")
        XCTAssertTrue(viewModel.hasOlderServerReconstructionPages)
        XCTAssertTrue(viewModel.hasMoreMessages)
    }

    func testReconnectGapBackfillCapKeepsLatestContiguousWindowPageable() async {
        let (viewModel, sessions) = makeViewModel()
        let previousEvents = rawMessageEvents(range: 1...100)
        viewModel.loadedReconstructionEvents = previousEvents
        viewModel.allReconstructedMessages = UnifiedEventTransformer.transformPersistedEvents(
            previousEvents,
            presorted: true
        )
        viewModel.replaceAllMessages(with: viewModel.allReconstructedMessages)
        viewModel.displayedMessageCount = 100
        viewModel.hasInitiallyLoaded = true
        sessions.reconstructHandler = { _, _, beforeEventId in
            guard let beforeEventId,
                  let sequence = Int(beforeEventId.replacingOccurrences(of: "event-", with: "")) else {
                XCTFail("Expected an event sequence cursor")
                return self.reconstructResult(events: [], hasMoreEvents: false, oldestEventId: nil)
            }
            let precedingSequence = sequence - 1
            return self.reconstructResult(
                events: self.rawMessageEvents(range: precedingSequence...precedingSequence),
                hasMoreEvents: true,
                oldestEventId: "event-\(precedingSequence)"
            )
        }

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: rawMessageEvents(range: 1_000...1_000),
                hasMoreEvents: true,
                oldestEventId: "event-1000"
            )
        )

        XCTAssertEqual(sessions.reconstructCalls.count, 20)
        XCTAssertEqual(viewModel.loadedReconstructionEvents.first?.id, "event-980")
        XCTAssertEqual(viewModel.loadedReconstructionEvents.last?.id, "event-1000")
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "event-980")
        XCTAssertTrue(viewModel.hasOlderServerReconstructionPages)
    }

    func testInitialForkReconstructionPreservesServerChainOrderAndOldestCursor() async {
        let (viewModel, _) = makeViewModel()
        let parent = chainEvent(
            id: "parent-message",
            sessionId: "parent-session",
            type: "message.user",
            content: "parent prompt",
            sequence: 10
        )
        let forkRoot = chainEvent(
            id: "fork-root",
            sessionId: "test-session",
            type: "session.fork",
            content: "",
            sequence: 0
        )
        let child = chainEvent(
            id: "child-message-1",
            sessionId: "test-session",
            type: "message.user",
            content: "child prompt",
            sequence: 1
        )

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [parent, forkRoot, child],
                hasMoreEvents: false,
                oldestEventId: parent.id
            )
        )

        XCTAssertEqual(
            viewModel.loadedReconstructionEvents.map(\.id),
            [parent.id, forkRoot.id, child.id]
        )
        XCTAssertEqual(viewModel.reconstructionOldestEventId, parent.id)
        XCTAssertEqual(
            viewModel.messages.compactMap { textContent($0) },
            ["parent prompt", "child prompt"]
        )
    }

    func testForkReconnectBackfillsOnlyChildSequenceGap() async {
        let (viewModel, sessions) = makeViewModel()
        let parent = chainEvent(
            id: "parent-message",
            sessionId: "parent-session",
            type: "message.user",
            content: "parent prompt",
            sequence: 1_000
        )
        let forkRoot = chainEvent(
            id: "fork-root",
            sessionId: "test-session",
            type: "session.fork",
            content: "",
            sequence: 0
        )
        let child1 = chainEvent(
            id: "child-message-1",
            sessionId: "test-session",
            type: "message.user",
            content: "child one",
            sequence: 1
        )
        let child2 = chainEvent(
            id: "child-message-2",
            sessionId: "test-session",
            type: "message.user",
            content: "child two",
            sequence: 2
        )
        let child3 = chainEvent(
            id: "child-message-3",
            sessionId: "test-session",
            type: "message.user",
            content: "child three",
            sequence: 3
        )
        let previous = [parent, forkRoot, child1]
        viewModel.loadedReconstructionEvents = previous
        viewModel.allReconstructedMessages = UnifiedEventTransformer.reconstructSessionState(
            from: previous,
            presorted: true
        ).messages
        viewModel.replaceAllMessages(with: viewModel.allReconstructedMessages)
        viewModel.displayedMessageCount = viewModel.messages.count
        viewModel.hasInitiallyLoaded = true

        sessions.reconstructHandler = { _, _, beforeEventId in
            XCTAssertEqual(beforeEventId, child3.id)
            return self.reconstructResult(
                events: [child2],
                hasMoreEvents: false,
                oldestEventId: child2.id
            )
        }

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [child3],
                hasMoreEvents: true,
                oldestEventId: child3.id
            )
        )

        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), [child3.id])
        XCTAssertEqual(
            viewModel.loadedReconstructionEvents.map(\.id),
            [parent.id, forkRoot.id, child1.id, child2.id, child3.id]
        )
        XCTAssertEqual(
            viewModel.messages.compactMap { textContent($0) },
            ["parent prompt", "child one", "child two", "child three"]
        )
    }

    func testForkReconnectMergesOverlappingServerChainInLinearOrder() async {
        let (viewModel, _) = makeViewModel()
        let parent = chainEvent(
            id: "parent-message",
            sessionId: "parent-session",
            type: "message.user",
            content: "parent prompt",
            sequence: 1_000
        )
        let forkRoot = chainEvent(
            id: "fork-root",
            sessionId: "test-session",
            type: "session.fork",
            content: "",
            sequence: 0
        )
        let child1 = chainEvent(
            id: "child-message-1",
            sessionId: "test-session",
            type: "message.user",
            content: "child one",
            sequence: 1
        )
        let child2 = chainEvent(
            id: "child-message-2",
            sessionId: "test-session",
            type: "message.user",
            content: "child two",
            sequence: 2
        )
        let child3 = chainEvent(
            id: "child-message-3",
            sessionId: "test-session",
            type: "message.user",
            content: "child three",
            sequence: 3
        )
        let previous = [parent, forkRoot, child1, child2]
        viewModel.loadedReconstructionEvents = previous
        viewModel.allReconstructedMessages = UnifiedEventTransformer.reconstructSessionState(
            from: previous,
            presorted: true
        ).messages
        viewModel.replaceAllMessages(with: viewModel.allReconstructedMessages)
        viewModel.displayedMessageCount = viewModel.messages.count
        viewModel.hasInitiallyLoaded = true

        await viewModel.processReconstructionResult(
            reconstructResult(
                events: [forkRoot, child1, child2, child3],
                hasMoreEvents: true,
                oldestEventId: forkRoot.id
            )
        )

        XCTAssertEqual(
            viewModel.loadedReconstructionEvents.map(\.id),
            [parent.id, forkRoot.id, child1.id, child2.id, child3.id]
        )
        XCTAssertEqual(viewModel.reconstructionOldestEventId, parent.id)
        XCTAssertEqual(
            viewModel.messages.compactMap { textContent($0) },
            ["parent prompt", "child one", "child two", "child three"]
        )
    }

}
