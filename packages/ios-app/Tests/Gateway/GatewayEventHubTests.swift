import Foundation
import Testing
@testable import TronMobile

struct GatewayEventHubTests {
    private func delivery(_ topic: String = "session.progress", id: Int = 1, value: Int = 0) -> GatewayEventDelivery {
        GatewayEventDelivery(connectionID: id, event: GatewayEvent(
            type: "event", topic: topic, sessionId: nil,
            payload: .object(["value": .number(Double(value))])
        ))
    }

    @Test("byte rejection reports the unchanged admission snapshot")
    func byteRejectionIsAtomic() async {
        let clock = ManualClock()
        let hub = GatewayEventHub(policy: .init(maximumEvents: 10, maximumBytes: 100), clock: clock.clock)
        _ = await hub.admit(delivery(), bytes: 90)
        let before = await hub.snapshot()
        let rejected = await hub.admit(delivery(), bytes: 11)
        #expect(!rejected.accepted)
        #expect(rejected.reason == .byteLimit)
        #expect(rejected.admittedBytes == 11)
        #expect(rejected.snapshot == before)
        #expect(await hub.snapshot() == before)
        await hub.finish()
    }

    @Test("oversized and count-limit predicates remain distinct")
    func capacityPredicates() async {
        let hub = GatewayEventHub(policy: .init(maximumEvents: 1, maximumBytes: 100))
        let oversized = await hub.admit(delivery(), bytes: 101)
        #expect(oversized.reason == .oversizedEvent)
        #expect(oversized.snapshot.bufferedEventCount == 0)
        _ = await hub.admit(delivery(), bytes: 10)
        let count = await hub.admit(delivery(), bytes: 10)
        #expect(count.reason == .countLimit)
        #expect(count.snapshot.bufferedBytes == 10)
        #expect(count.snapshot.admittedCount == 1)
        await hub.finish()
    }

    @Test("a rejected coalesced replacement preserves bytes and original delivery")
    func coalescedRejection() async throws {
        let clock = ManualClock()
        let hub = GatewayEventHub(policy: .init(maximumEvents: 10, maximumBytes: 100), clock: clock.clock)
        _ = await hub.admit(delivery("session.listChanged", value: 1), bytes: 40)
        _ = await hub.admit(delivery(), bytes: 40)
        let before = await hub.snapshot()
        let rejected = await hub.admit(delivery("session.listChanged", value: 2), bytes: 70)
        #expect(rejected.reason == .byteLimit)
        #expect(rejected.snapshot == before)
        do {
            let first = try await withTestWatchdog(timeout: .seconds(3)) { await hub.next() }
            #expect(first?.event.payload.objectValue?["value"]?.intValue == 1)
        } catch {
            await hub.finish()
            throw error
        }
        await hub.finish()
    }

    @Test("coalescing preserves oldest age and dequeue-to-next identifies unfinished consumption")
    func coalescingAndConsumerAges() async throws {
        let clock = ManualClock()
        let hub = GatewayEventHub(policy: .init(maximumEvents: 10, maximumBytes: 100), clock: clock.clock)
        _ = await hub.admit(delivery("session.listChanged"), bytes: 40)
        clock.advance(by: .milliseconds(50))
        _ = await hub.admit(delivery(), bytes: 40)
        clock.advance(by: .milliseconds(50))
        let replacement = await hub.admit(delivery("session.listChanged", value: 2), bytes: 10)
        #expect(replacement.snapshot.oldestQueuedAgeMilliseconds == 100)
        #expect(replacement.snapshot.bufferedBytes == 50)
        do {
            _ = try await withTestWatchdog(timeout: .seconds(3)) { await hub.next() }
            clock.advance(by: .milliseconds(25))
            let held = await hub.snapshot()
            #expect(held.oldestQueuedAgeMilliseconds == 75)
            #expect(held.dequeueWaitAgeMilliseconds == 25)
            #expect(held.dequeueWaitTopic == "session.listChanged")
            #expect(held.dequeueWaitConnectionID == 1)
            await hub.reset(connectionID: 1)
            let reset = await hub.snapshot()
            #expect(reset.dequeueWaitAgeMilliseconds == nil)
            #expect(reset.admittedCount == 0)
            #expect(reset.byteHighWaterMark == 0)
        } catch {
            await hub.finish()
            throw error
        }
        await hub.finish()
    }

    @Test("threshold emissions do not chatter after drain and re-crossing")
    func pressureCrossingsAreBounded() async throws {
        let hub = GatewayEventHub(policy: .init(maximumEvents: 100, maximumBytes: 100))
        do {
            for index in 0..<10 {
                let admission = await hub.admit(delivery("session.listChanged"), bytes: 50)
                #expect(admission.pressureChanged == (index == 0))
                #expect(admission.snapshot.pressureCrossings == 1)
                _ = try await withTestWatchdog(timeout: .seconds(3)) { await hub.next() }
            }
            let full = await hub.admit(delivery(), bytes: 100)
            #expect(full.pressureChanged)
            #expect(full.snapshot.pressureCrossings == 4)
            await hub.reset(connectionID: 1)
            let successor = await hub.admit(delivery(id: 2), bytes: 50)
            #expect(successor.pressureChanged)
            #expect(successor.snapshot.pressureCrossings == 1)
            #expect(successor.snapshot.admittedCount == 1)
        } catch {
            await hub.finish()
            throw error
        }
        await hub.finish()
    }

    @Test("reset removes a predecessor without clearing successor evidence")
    func resetPreservesSuccessorEvidence() async {
        let hub = GatewayEventHub(policy: .init(maximumEvents: 10, maximumBytes: 100))
        _ = await hub.admit(delivery("session.progress", id: 1), bytes: 20)
        _ = await hub.admit(delivery("session.progress", id: 2), bytes: 20)
        await hub.reset(connectionID: 1)
        let snapshot = await hub.snapshot()
        #expect(snapshot.bufferedEventCount == 1)
        #expect(snapshot.bufferedBytes == 20)
        #expect(snapshot.admittedCount == 1)
        #expect(snapshot.pressureLevels.isEmpty)
        await hub.finish()
    }

    @Test("retired and predecessor frames cannot consume successor capacity or evidence")
    func staleAdmissionIsRejected() async {
        let clock = ManualClock()
        let hub = GatewayEventHub(policy: .init(maximumEvents: 10, maximumBytes: 100), clock: clock.clock)
        _ = await hub.admit(delivery(id: 1), bytes: 10)
        await hub.reset(connectionID: 1)
        let retired = await hub.admit(delivery(id: 1), bytes: 10)
        #expect(!retired.accepted)
        #expect(retired.reason == .retiredEpoch)
        #expect(retired.snapshot.bufferedEventCount == 0)
        _ = await hub.admit(delivery(id: 2), bytes: 50)
        let before = await hub.snapshot()
        let stale = await hub.admit(delivery(id: 1), bytes: 1)
        #expect(!stale.accepted)
        #expect(stale.reason == .retiredEpoch)
        #expect(stale.snapshot == before)
        await hub.reset(connectionID: 2)
        #expect(await hub.snapshot().bufferedEventCount == 0)
        await hub.finish()
    }

    @Test("only an exact retirement can publish its final control event")
    func retirementNotification() async {
        let clock = ManualClock()
        let hub = GatewayEventHub(clock: clock.clock)
        await hub.reset(connectionID: 1, notification: delivery("transport.disconnected").event)
        #expect(await hub.snapshot().bufferedEventCount == 1)
        #expect(await hub.admit(delivery(id: 1), bytes: 1).reason == .retiredEpoch)
        _ = await hub.admit(delivery(id: 2), bytes: 1)
        let before = await hub.snapshot()
        await hub.reset(connectionID: 1, notification: delivery("transport.disconnected").event)
        #expect(await hub.snapshot() == before)
        await hub.finish()
    }

    @Test("successor admission starts with its own capacity rather than a predecessor backlog")
    func successorCapacity() async {
        let hub = GatewayEventHub(policy: .init(maximumEvents: 10, maximumBytes: 100))
        _ = await hub.admit(delivery(id: 1), bytes: 80)
        let successor = await hub.admit(delivery(id: 2), bytes: 40)
        #expect(successor.accepted)
        #expect(successor.snapshot.bufferedBytes == 40)
        #expect(successor.snapshot.admittedCount == 1)
        await hub.finish()
    }

    @Test("successor deliveries supersede predecessor projections and topics remain privacy-bounded")
    func epochKeysAndTopicPrivacy() async throws {
        let hub = GatewayEventHub()
        _ = await hub.admit(delivery("session.listChanged", id: 1), bytes: 10)
        let second = await hub.admit(delivery("session.listChanged", id: 2), bytes: 10)
        #expect(second.snapshot.bufferedEventCount == 1)
        let unknown = await hub.admit(delivery("credential-shaped-unrecognized-topic", id: 2), bytes: 1)
        #expect(unknown.topic == "other")
        let recognized = await hub.admit(delivery("session.progress", id: 2), bytes: 1)
        #expect(recognized.topic == "session.progress")
        await hub.finish()
    }
}
