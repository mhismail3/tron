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
    func testDisconnectResetsState() async {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        await rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("EngineClient can be deallocated without crash")
    func testDeallocationSafety() async {
        var rpc: EngineClient? = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        #expect(rpc != nil)
        rpc = nil
        #expect(rpc == nil)
    }

    @Test("Multiple disconnect calls are safe")
    func testMultipleDisconnects() async {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        await rpc.disconnect()
        await rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
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
        #expect(EngineClientConnectionPolicy.shouldDiscardExistingTransport(
            hasTransport: true,
            state: .connected
        ) == false)
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
    }

    @Test("Stream cursor store records subscription tail before first event")
    func testStreamCursorStorePersistsSubscriptionTail() {
        let suiteName = "EngineClientObservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EngineStreamCursorStore(userDefaults: defaults)
        let key = EngineStreamCursorKey(
            serverOrigin: "127.0.0.1:9847",
            topic: "events.session",
            sessionId: "session-a",
            workspaceId: nil,
            filterHash: "sessionId=session-a"
        )

        store.save(EngineStreamCursor(rawValue: 44), for: key)
        store.save(EngineStreamCursor(rawValue: 12), for: key)

        #expect(store.cursor(for: key) == EngineStreamCursor(rawValue: 44))
    }

    @Test("Session live subscriptions do not replay durable stream cursors")
    func testSessionSubscriptionsStartAtLiveTail() {
        #expect(EngineClientStreamSubscriptionPolicy.sessionEventSubscriptionCursor(stored: nil) == nil)
        #expect(EngineClientStreamSubscriptionPolicy.sessionEventSubscriptionCursor(
            stored: EngineStreamCursor(rawValue: 0)
        ) == nil)
        #expect(EngineClientStreamSubscriptionPolicy.sessionEventSubscriptionCursor(
            stored: EngineStreamCursor(rawValue: 4_572)
        ) == nil)
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
}
