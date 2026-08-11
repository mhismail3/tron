import Testing
import Foundation
@testable import TronMobile

// MARK: - EngineClient Observation Tests

@Suite("EngineClient Observation")
@MainActor
struct EngineClientObservationTests {

    @Test("Initial connection state is disconnected")
    func testInitialState() {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("Disconnect cancels observation and resets state")
    func testDisconnectResetsState() {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("Installed connection observation releases its engine client")
    func testConnectionObservationReleasesOwner() async {
        let recorder = HostedEngineAttemptRecorder()
        var rpc: EngineClient? = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65531/engine")!,
            sessionAttemptDirective: recorder.handle
        )
        weak let retainedClient = rpc

        await rpc?.connect()
        var connection = rpc?.engineConnection
        weak let retainedConnection = connection
        #expect(recorder.requests.count == 1)
        #expect(connection != nil)

        connection?.connectionState = .connecting
        for _ in 0..<100 where rpc?.connectionState != .connecting {
            await Task.yield()
        }
        #expect(rpc?.connectionState == .connecting)

        connection = nil
        rpc = nil
        for _ in 0..<100 where retainedClient != nil || retainedConnection != nil {
            await Task.yield()
        }

        #expect(retainedClient == nil)
        #expect(retainedConnection == nil)
    }

    @Test("Multiple disconnect calls are safe")
    func testMultipleDisconnects() {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        rpc.disconnect()
        rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("handled policy captures completed requests before any live session exists")
    func testHandledConnectCreatesNoSession() async throws {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            bearerTokenProvider: { "fixture-token" },
            sessionAttemptDirective: recorder.handle
        )

        await rpc.connect()

        let request = try #require(recorder.requests.last)
        #expect(request.url?.absoluteString == "ws://127.0.0.1:65530/engine")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(rpc.engineConnection?.urlSession == nil)
        #expect(rpc.engineConnection?.engineConnectionTask == nil)
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("background retirement discards the old client transport epoch")
    func testBackgroundRetiresClientTransport() async throws {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            sessionAttemptDirective: recorder.handle
        )
        await rpc.connect()
        let retired = try #require(rpc.engineConnection)

        rpc.setBackgroundState(true)

        #expect(rpc.connectionState == .disconnected)
        #expect(rpc.engineConnection == nil)
        #expect(retired.connectionState == .disconnected)

        await rpc.manualRetry()
        #expect(rpc.engineConnection == nil)

        await rpc.resumeFromBackground()
        let replacement = try #require(rpc.engineConnection)
        #expect(replacement !== retired)
        #expect(recorder.requests.count >= 2)
        rpc.disconnect()
    }

    @Test("background retirement preserves the selected session subscription interest")
    func testBackgroundPreservesSessionInterest() async {
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        rpc.setCurrentSessionId("session-a")
        for _ in 0..<10 { await Task.yield() }
        #expect(rpc.currentSessionId == "session-a")
        #expect(!rpc.sessionSubscriptionInterests.isEmpty)

        rpc.setBackgroundState(true)

        #expect(rpc.currentSessionId == "session-a")
        #expect(!rpc.sessionSubscriptionInterests.isEmpty)
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("background retirement preserves requested worker monitoring")
    func testBackgroundPreservesWorkerMonitoringInterest() async {
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )

        do {
            try await rpc.ensureWorkerEventSubscriptions()
            Issue.record("expected offline worker subscription to fail")
        } catch {
            // The durable monitoring intent is accepted before transport work.
        }
        #expect(rpc.workerEventSubscriptionsRequested)

        rpc.setBackgroundState(true)
        #expect(rpc.workerEventSubscriptionsRequested)

        rpc.disconnect()
        #expect(!rpc.workerEventSubscriptionsRequested)
    }

    @Test("background state rejects late connection work until foreground")
    func testBackgroundDefersLateConnectionWork() async {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            sessionAttemptDirective: recorder.handle
        )

        rpc.setBackgroundState(true)
        await rpc.connect()
        await rpc.manualRetry()

        #expect(recorder.requests.isEmpty)
        #expect(rpc.engineConnection == nil)
        #expect(rpc.connectionState == .disconnected)

        rpc.setBackgroundState(false)
        await rpc.connect()
        #expect(recorder.requests.count == 1)
        rpc.disconnect()
    }

    @Test("background retirement keeps authorization parked")
    func testBackgroundKeepsAuthorizationParked() async throws {
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        await rpc.connect()
        let connection = try #require(rpc.engineConnection)
        connection.markUnauthorized(reason: "Re-pair required")
        for _ in 0..<10 where rpc.connectionState != connection.connectionState {
            await Task.yield()
        }

        rpc.setBackgroundState(true)

        #expect(rpc.engineConnection === connection)
        #expect(rpc.connectionState == .unauthorized(reason: "Re-pair required"))
    }

    @Test("Concurrent connect callers await one shared attempt")
    func testConcurrentConnectIsSingleFlight() async {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            sessionAttemptDirective: recorder.handle
        )

        async let first: Void = rpc.connect()
        async let second: Void = rpc.connect()
        _ = await (first, second)

        #expect(recorder.requests.count == 1)
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("manual retry and reconnect preserve the immutable handled policy")
    func testHandledRetryAndReconnectRemainHandled() async {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65529/engine")!,
            sessionAttemptDirective: recorder.handle
        )

        await rpc.manualRetry()
        rpc.disconnect()
        await rpc.reconnect()

        #expect(recorder.requests.count >= 2)
        #expect(rpc.engineConnection?.urlSession == nil)
        #expect(rpc.engineConnection?.engineConnectionTask == nil)
        rpc.disconnect()
    }

    @Test("explicit disconnect prevents deferred reads from resurrecting a retired client")
    func explicitDisconnectIsTerminalForDeferredReads() async {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65529/engine")!,
            sessionAttemptDirective: recorder.handle
        )
        await rpc.connect()
        let attemptsBeforeRetirement = recorder.requests.count

        rpc.disconnect()

        do {
            let _: EmptyParams = try await rpc.invokeRead(
                functionId: "test::read",
                payload: EmptyParams()
            )
            Issue.record("expected an explicitly retired client to reject reads")
        } catch {
            #expect(error as? EngineConnectionError == .notConnected)
        }
        #expect(recorder.requests.count == attemptsBeforeRetirement)
    }

    @Test("an offline read owns one connection request and cancels cleanly")
    func offlineReadWaitsWithoutSpinning() async {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65529/engine")!,
            sessionAttemptDirective: recorder.handle
        )
        let read = Task { @MainActor () -> Error? in
            do {
                let _: EmptyParams = try await rpc.invokeRead(
                    functionId: "test::read",
                    payload: EmptyParams()
                )
                return nil
            } catch {
                return error
            }
        }

        for _ in 0..<100 where recorder.requests.isEmpty {
            await Task.yield()
        }
        #expect(recorder.requests.count == 1)

        read.cancel()
        let error = await read.value
        #expect(error is CancellationError)
        #expect(recorder.requests.count == 1)
        rpc.disconnect()
    }

    @Test("a caller-managed read never waits behind transport recovery")
    func currentTransportReadFailsFastWhileOffline() async {
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65529/engine")!,
            sessionAttemptDirective: recorder.handle
        )
        await rpc.connect()
        let attemptCount = recorder.requests.count

        do {
            let _: EmptyParams = try await rpc.invokeRead(
                functionId: "test::interactive-read",
                payload: EmptyParams(),
                options: EngineInvocationOptions(
                    timeout: EngineSessionSynchronizationPolicy.requestTimeout,
                    readRecoveryPolicy: .currentTransport
                )
            )
            Issue.record("expected the current transport read to fail while offline")
        } catch {
            #expect(error as? EngineConnectionError == .notConnected)
        }

        #expect(recorder.requests.count == attemptCount)
        rpc.disconnect()
    }

    @Test("Connect policy discards stale disconnected transports")
    func testConnectPolicyDiscardsStaleDisconnectedTransport() {
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .disconnected) == false)
        #expect(EngineClientConnectionPolicy.shouldDiscardExistingTransport(
            hasTransport: true,
            state: .disconnected
        ))
    }

    @Test("Connect policy preserves active in-flight transports")
    func testConnectPolicyPreservesActiveTransport() {
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .connected))
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .connecting))
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .reconnecting(attempt: 1, nextRetrySeconds: 2)))
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .deployRestarting(remainingSeconds: 3)))
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(
            state: .unauthorized(reason: "Re-pair required")
        ))
        #expect(EngineClientConnectionPolicy.shouldDiscardExistingTransport(
            hasTransport: true,
            state: .connected
        ) == false)
        #expect(EngineClientConnectionPolicy.shouldDiscardExistingTransport(
            hasTransport: true,
            state: .unauthorized(reason: "Re-pair required")
        ) == false)
    }

    @Test("only a foreground live initial attempt enters automatic recovery")
    func testInitialAutomaticRecoveryPolicy() {
        #expect(EngineClientConnectionPolicy.shouldOwnAutomaticRecovery(
            attemptedLiveSession: true,
            isInBackground: false,
            state: .disconnected
        ))
        #expect(!EngineClientConnectionPolicy.shouldOwnAutomaticRecovery(
            attemptedLiveSession: false,
            isInBackground: false,
            state: .disconnected
        ))
        #expect(!EngineClientConnectionPolicy.shouldOwnAutomaticRecovery(
            attemptedLiveSession: true,
            isInBackground: true,
            state: .disconnected
        ))
        #expect(!EngineClientConnectionPolicy.shouldOwnAutomaticRecovery(
            attemptedLiveSession: true,
            isInBackground: false,
            state: .unauthorized(reason: "Re-pair required")
        ))
    }

    @Test("Stream subscriptions are per socket and clear on disconnect")
    func testStreamSubscriptionPolicyClearsOnDisconnect() {
        #expect(EngineClientStreamSubscriptionPolicy.shouldClearSubscriptions(
            previous: .connected,
            next: .reconnecting(attempt: 1, nextRetrySeconds: 0)
        ))
        #expect(EngineClientStreamSubscriptionPolicy.shouldClearSubscriptions(
            previous: .connected,
            next: .failed(reason: "closed")
        ))
        #expect(!EngineClientStreamSubscriptionPolicy.shouldClearSubscriptions(
            previous: .disconnected,
            next: .connecting
        ))
        #expect(EngineClientStreamSubscriptionPolicy.shouldClearSubscriptions(
            previous: .connected,
            next: .connected,
            transportChanged: true
        ))
    }

    @Test("rapid connected-to-connected generation replacement restores interests")
    func testStreamSubscriptionPolicyHandlesCollapsedReconnectEdge() {
        #expect(EngineClientStreamSubscriptionPolicy.shouldResubscribe(
            previous: .connected,
            next: .connected,
            hasCurrentSession: true,
            transportChanged: true
        ))
        #expect(!EngineClientStreamSubscriptionPolicy.shouldResubscribe(
            previous: .connected,
            next: .connected,
            hasCurrentSession: true,
            transportChanged: false
        ))
    }

    @Test("collapsed reconnect advances the observable continuity generation")
    func testCollapsedReconnectAdvancesContinuityGeneration() async throws {
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65530/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        await rpc.connect()
        let connection = try #require(rpc.engineConnection)
        let firstTask = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:65530/engine")!
        )
        let secondTask = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:65530/engine")!
        )
        defer {
            firstTask.cancel()
            secondTask.cancel()
            rpc.disconnect()
        }

        _ = connection.installTransportOwnership(firstTask)
        connection.markProtocolReady(maxMessageSize: 1_024)
        for _ in 0..<100 where rpc.continuityGeneration < 1 {
            await Task.yield()
        }
        #expect(rpc.continuityGeneration == 1)

        // Mutate through reconnecting and back to connected without yielding,
        // reproducing a UI observation that samples connected on both sides.
        connection.connectionState = .reconnecting(
            attempt: 1,
            nextRetrySeconds: 0
        )
        _ = connection.installTransportOwnership(secondTask)
        connection.markProtocolReady(maxMessageSize: 2_048)
        for _ in 0..<100 where rpc.continuityGeneration < 2 {
            await Task.yield()
        }

        #expect(rpc.connectionState == .connected)
        #expect(rpc.continuityGeneration == 2)
    }

    @Test("Stream subscriptions resubscribe current session after reconnect")
    func testStreamSubscriptionPolicyResubscribesAfterReconnect() {
        #expect(EngineClientStreamSubscriptionPolicy.shouldResubscribe(
            previous: .reconnecting(attempt: 1, nextRetrySeconds: 0),
            next: .connected,
            hasCurrentSession: true
        ))
        #expect(!EngineClientStreamSubscriptionPolicy.shouldResubscribe(
            previous: .reconnecting(attempt: 1, nextRetrySeconds: 0),
            next: .connected,
            hasCurrentSession: false
        ))
        #expect(!EngineClientStreamSubscriptionPolicy.shouldResubscribe(
            previous: .connected,
            next: .connected,
            hasCurrentSession: true
        ))
    }

    @Test("Switching current sessions releases stale presentation interest")
    func testCurrentSessionInterestHasExactLifecycle() async {
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65527/engine")!
        )

        rpc.setCurrentSessionId("session-a")
        for _ in 0..<20 where rpc.sessionSubscriptionInterests.isEmpty {
            await Task.yield()
        }
        #expect(rpc.sessionSubscriptionInterests.count == 1)
        #expect(rpc.sessionSubscriptionInterests.values.first == [.presentation])

        rpc.setCurrentSessionId("session-b")
        for _ in 0..<20 where rpc.sessionSubscriptionInterests.keys.first?.sessionId != "session-b" {
            await Task.yield()
        }
        #expect(rpc.sessionSubscriptionInterests.count == 1)
        #expect(rpc.sessionSubscriptionInterests.keys.first?.sessionId == "session-b")

        rpc.setCurrentSessionId(nil)
        for _ in 0..<20 where !rpc.sessionSubscriptionInterests.isEmpty {
            await Task.yield()
        }
        #expect(rpc.sessionSubscriptionInterests.isEmpty)
    }

    @Test("Processing and presentation interests release independently")
    func testSessionInterestsAreReferenceOwned() async {
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65526/engine")!
        )
        rpc.setCurrentSessionId("session-a")
        for _ in 0..<20 where rpc.sessionSubscriptionInterests.isEmpty {
            await Task.yield()
        }
        do {
            try await rpc.setProcessingSessionEventSubscription(
                sessionId: "session-a",
                workspaceId: nil,
                isActive: true
            )
        } catch {
            // A disconnected transport cannot subscribe, but it retains the
            // processing interest for automatic reconnect.
        }
        #expect(rpc.sessionSubscriptionInterests.values.first == [
            .presentation,
            .processing,
        ])

        rpc.setCurrentSessionId(nil)
        for _ in 0..<20 where rpc.sessionSubscriptionInterests.values.first?.contains(.presentation) == true {
            await Task.yield()
        }
        #expect(rpc.sessionSubscriptionInterests.values.first == [.processing])

        try? await rpc.setProcessingSessionEventSubscription(
            sessionId: "session-a",
            workspaceId: nil,
            isActive: false
        )
        #expect(rpc.sessionSubscriptionInterests.isEmpty)
    }

    @Test("Only closed worker lifecycle topics invalidate the dashboard projection")
    func testWorkerProjectionTopicsAreClosed() {
        #expect(EngineClientStreamSubscriptionPolicy.workerProjectionTopics == [
            "worker.lifecycle",
            "worker.invocations",
            "worker.role_review",
        ])
        #expect(EngineClientStreamSubscriptionPolicy.isWorkerProjectionTopic("worker.lifecycle"))
        #expect(EngineClientStreamSubscriptionPolicy.isWorkerProjectionTopic("worker.invocations"))
        #expect(EngineClientStreamSubscriptionPolicy.isWorkerProjectionTopic("worker.role_review"))
        #expect(EngineClientStreamSubscriptionPolicy.isWorkerLifecycleTopic("worker.lifecycle"))
        #expect(EngineClientStreamSubscriptionPolicy.isWorkerLifecycleTopic("worker.role_review"))
        #expect(!EngineClientStreamSubscriptionPolicy.isWorkerLifecycleTopic("worker.invocations"))
        #expect(!EngineClientStreamSubscriptionPolicy.isWorkerProjectionTopic("events.session"))
        #expect(!EngineClientStreamSubscriptionPolicy.isWorkerProjectionTopic(nil))
    }

    @Test("Worker invalidation coalescing preserves every affected session")
    func testWorkerInvalidationCoalescingPreservesScope() {
        var accumulator = WorkerProjectionInvalidationAccumulator()
        accumulator.record(topic: "worker.invocations", sessionId: "session-a")
        accumulator.record(topic: "worker.invocations", sessionId: "session-b")
        accumulator.record(topic: "worker.invocations", sessionId: "session-a")
        accumulator.record(topic: "worker.invocations", sessionId: nil)
        accumulator.record(topic: "worker.lifecycle", sessionId: nil)
        accumulator.record(topic: "worker.role_review", sessionId: nil)

        let invalidation = accumulator.take()
        #expect(invalidation.affectedSessionIds == ["session-a", "session-b"])
        #expect(invalidation.includesUnscopedInvocations)
        #expect(invalidation.lifecycleChanged)
        #expect(invalidation.affectsSession("session-a"))
        #expect(!invalidation.affectsSession("session-c"))
        #expect(accumulator.isEmpty)
    }

    @Test("Typed worker invalidations do not refresh unrelated sessions")
    func testWorkerInvalidationSessionPolicy() {
        let invalidation = WorkerProjectionInvalidation(
            affectedSessionIds: ["session-a"],
            includesUnscopedInvocations: true,
            lifecycleChanged: false
        )
        #expect(WorkerProjectionInvalidation.affectsSession(
            notificationObject: invalidation,
            sessionId: "session-a"
        ))
        #expect(!WorkerProjectionInvalidation.affectsSession(
            notificationObject: invalidation,
            sessionId: "session-b"
        ))
        #expect(WorkerProjectionInvalidation.affectsSession(
            notificationObject: nil,
            sessionId: "legacy-session"
        ))
    }

    @Test("Agent invalidation coalescing preserves session scope and global hints")
    func testAgentCoordinationInvalidationCoalescing() {
        var accumulator = AgentCoordinationInvalidationAccumulator()
        accumulator.record(sessionId: "session-a")
        accumulator.record(sessionId: "session-b")
        accumulator.record(sessionId: "session-a")

        let scoped = accumulator.take()
        #expect(scoped.affectedSessionIds == ["session-a", "session-b"])
        #expect(!scoped.includesUnscopedChanges)
        #expect(scoped.affectsSession("session-a"))
        #expect(!scoped.affectsSession("session-c"))

        accumulator.record(sessionId: nil)
        let global = accumulator.take()
        #expect(global.includesUnscopedChanges)
        #expect(global.affectsSession("any-session"))
        #expect(AgentCoordinationProjectionInvalidation.affectsSession(
            notificationObject: nil,
            sessionId: "legacy-notification"
        ))
    }

    @Test("Profile surface reads are single-flight across concurrent consumers")
    func testSurfaceSnapshotLoaderCoalescesConcurrentReads() async throws {
        let loader = EngineSurfaceSnapshotLoader()
        var operationCount = 0
        var release: CheckedContinuation<EngineIntrospectionSnapshotDTO, Never>?
        let waiters = (0..<20).map { _ in
            Task { @MainActor in
                try await loader.load {
                    operationCount += 1
                    return await withCheckedContinuation { continuation in
                        release = continuation
                    }
                }
            }
        }

        while release == nil {
            await Task.yield()
        }
        #expect(operationCount == 1)
        release?.resume(returning: EngineIntrospectionSnapshotDTO(
            dispatchStopped: false,
            activeEngineHooks: [],
            activeClientActions: [],
            fixedTools: [],
            surface: AgentToolSurfaceDTO(
                catalogRevision: 1,
                surfaceHash: "single-flight",
                fixedToolCount: 0,
                projectedWorkerCount: 0,
                availableWorkerCount: 0,
                availableWorkers: []
            ),
            workers: []
        ))
        for waiter in waiters {
            _ = try await waiter.value
        }
        #expect(operationCount == 1)
    }

    @Test("Stream ACK coalescer sends only latest cursor per subscription")
    func testStreamAckCoalescerKeepsLatestCursor() {
        var coalescer = EngineStreamAckCoalescer()
        let initialSchedule = coalescer.record(subscriptionId: "sub-1", cursor: EngineStreamCursor(rawValue: 10))
        let laterCursorSchedule = coalescer.record(subscriptionId: "sub-1", cursor: EngineStreamCursor(rawValue: 11))
        let olderCursorSchedule = coalescer.record(subscriptionId: "sub-1", cursor: EngineStreamCursor(rawValue: 9))
        #expect(initialSchedule)
        #expect(!laterCursorSchedule)
        #expect(!olderCursorSchedule)
        let cursor = coalescer.takeForFlush(subscriptionId: "sub-1")
        let needsReschedule = coalescer.completeFlush(subscriptionId: "sub-1")
        #expect(cursor == EngineStreamCursor(rawValue: 11))
        #expect(!needsReschedule)
        let nextSchedule = coalescer.record(subscriptionId: "sub-1", cursor: EngineStreamCursor(rawValue: 12))
        #expect(nextSchedule)
        coalescer.remove(subscriptionId: "sub-1")
        #expect(coalescer.takeForFlush(subscriptionId: "sub-1") == nil)
    }

    @Test("Stream ACK coalescer reschedules when events arrive during flush")
    func testStreamAckCoalescerReschedulesDuringFlush() {
        var coalescer = EngineStreamAckCoalescer()
        let initialSchedule = coalescer.record(subscriptionId: "sub-1", cursor: EngineStreamCursor(rawValue: 20))
        #expect(initialSchedule)
        let firstCursor = coalescer.takeForFlush(subscriptionId: "sub-1")
        #expect(firstCursor == EngineStreamCursor(rawValue: 20))
        let inFlightSchedule = coalescer.record(subscriptionId: "sub-1", cursor: EngineStreamCursor(rawValue: 21))
        #expect(!inFlightSchedule)
        let needsReschedule = coalescer.completeFlush(subscriptionId: "sub-1")
        #expect(needsReschedule)
        let nextSchedule = coalescer.record(subscriptionId: "sub-1", cursor: EngineStreamCursor(rawValue: 22))
        #expect(nextSchedule)
        let secondCursor = coalescer.takeForFlush(subscriptionId: "sub-1")
        #expect(secondCursor == EngineStreamCursor(rawValue: 22))
    }

    @Test("Local subscriber overflow publishes an explicit recovery marker")
    func testLocalSubscriberOverflowPublishesRecoveryMarker() async throws {
        EventRegistry.shared.registerAll()
        let recorder = HostedEngineAttemptRecorder()
        let rpc = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65528/engine")!,
            sessionAttemptDirective: recorder.handle
        )
        await rpc.connect()
        let connection = try #require(rpc.engineConnection)
        let firstStream = rpc.events
        let secondStream = rpc.events
        let payload = ServerEventPayload(
            type: AgentReadyPlugin.eventType,
            sessionId: "overflow-session",
            workspaceId: nil,
            timestamp: "2026-07-17T00:00:00Z",
            data: nil,
            runId: nil,
            sequence: nil,
            traceId: nil,
            parentInvocationId: nil,
            sourceEventId: nil,
            sourceSequence: nil,
            streamCursor: nil
        )
        let eventData = try JSONEncoder().encode(payload)

        for _ in 0...256 {
            connection.onEvent?(
                EngineEventDelivery(
                    topic: "events.session",
                    subscriptionId: nil,
                    cursor: nil,
                    event: payload,
                    eventData: eventData
                )
            )
        }

        var iterator = firstStream.makeAsyncIterator()
        var recovery: StreamRecoveryRequiredPlugin.Result?
        for _ in 0..<256 {
            guard let event = await iterator.next() else { break }
            if event.eventType == StreamRecoveryRequiredPlugin.eventType {
                recovery = event.getResult() as? StreamRecoveryRequiredPlugin.Result
                break
            }
        }

        #expect(recovery?.reason == "client_buffer_overflow")
        #expect(recovery?.droppedEventCount == 2)
        withExtendedLifetime(secondStream) {}
    }
}
