import Foundation

package enum GatewayDiagnosticTopicAdmission {
    static let recognizedTopics: Set<String> = [
        "session.snapshot", "session.rebaseline", "session.summary", "session.listChanged",
        "session.message", "session.progress", "session.toolProgress", "session.extensionActivity",
        "session.extensionPresentation", "session.compaction", "session.processActivity",
        "session.closed", "session.operationFailed", "session.extensionError",
        "session.structureChanged", "session.contextChanged", "session.resourcesChanged",
        "session.processTranscript.changed", "transport.disconnected", "transport.resyncRequired",
        "system.stopping", "notification.inbox.changed", "auth.prompt", "auth.event",
        "auth.completed", "automation.changed", "settings.changed", "trust.changed",
        "providers.changed", "packages.changed", "packages.progress", "packages.completed",
        "models.customChanged", "models.recentChanged", "models.catalogChanged", "mcp.changed", "devices.changed"
    ]

    package static func admit(_ topic: String) -> String {
        recognizedTopics.contains(topic) ? topic : "other"
    }
}

package struct GatewayEventBufferPolicy: Sendable {
    let maximumEvents: Int
    let maximumBytes: Int

    // Matches the Gateway synchronization quarantine count while the byte cap
    // remains the stricter cross-session memory bound.
    static let `default` = Self(maximumEvents: 1_024, maximumBytes: 2 * 1_024 * 1_024)
}

enum GatewayEventAdmissionReason: String, Sendable, Equatable {
    case countLimit = "count_limit"
    case byteLimit = "byte_limit"
    case oversizedEvent = "oversized_event"
    case retiredEpoch = "retired_epoch"
}

struct GatewayEventHubSnapshot: Sendable, Equatable {
    let bufferedEventCount: Int
    let bufferedBytes: Int
    let maximumEvents: Int
    let maximumBytes: Int
    let oldestQueuedAgeMilliseconds: Int
    let timeSinceLastDequeueMilliseconds: Int?
    let countHighWaterMark: Int
    let byteHighWaterMark: Int
    let admittedCount: Int
    let dequeuedCount: Int
    let pressureCrossings: Int
    let pressureLevels: [Int]
    let dequeueWaitAgeMilliseconds: Int?
    let dequeueWaitTopic: String?
    let dequeueWaitConnectionID: Int?
}

struct GatewayEventAdmission: Sendable, Equatable {
    let accepted: Bool
    let reason: GatewayEventAdmissionReason?
    let topic: String
    let admittedBytes: Int
    let snapshot: GatewayEventHubSnapshot
    let pressureChanged: Bool
}

actor GatewayEventHub {
    private struct BufferedDelivery {
        let delivery: GatewayEventDelivery
        let bytes: Int
        let key: String?
        let queuedAt: ContinuousClock.Instant
    }

    private let policy: GatewayEventBufferPolicy
    private let clock: MonotonicClock
    private var buffered: [BufferedDelivery] = []
    private var bufferedBytes = 0
    private var waiters: [(UUID, CheckedContinuation<GatewayEventDelivery?, Never>)] = []
    private var finished = false
    private var lastDequeuedAt: ContinuousClock.Instant?
    private var countHighWaterMark = 0
    private var byteHighWaterMark = 0
    private var admittedCount = 0
    private var dequeuedCount = 0
    private var pressureLevels: Set<Int> = []
    // Evidence follows the newest admitted epoch. During a suspended close,
    // successor admission can overlap removal of the predecessor's buffer;
    // stale deliveries must not reset successor counters or threshold state.
    private var evidenceConnectionID: Int?
    private var retiredThrough = Int.min
    private var dequeuedAt: ContinuousClock.Instant?
    private var dequeuedTopic: String?
    private var dequeuedConnectionID: Int?

    init(
        policy: GatewayEventBufferPolicy = .default,
        clock: MonotonicClock = .continuous
    ) {
        self.policy = policy
        self.clock = clock
    }

    func next() async -> GatewayEventDelivery? {
        clearDequeued()
        if let first = buffered.first {
            dequeue(first)
            markDequeued(first.delivery)
            return first.delivery
        }
        if finished || Task.isCancelled { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let first = buffered.first {
                    dequeue(first)
                    markDequeued(first.delivery)
                    continuation.resume(returning: first.delivery)
                } else if finished || Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Admission and its evidence are one actor operation. In particular, a
    /// coalesced replacement is preflighted before changing byte accounting, so
    /// a rejected replacement cannot leave the hub over its configured bound.
    func admit(_ delivery: GatewayEventDelivery, bytes: Int) -> GatewayEventAdmission {
        guard !finished, delivery.connectionID > retiredThrough,
              evidenceConnectionID.map({ delivery.connectionID >= $0 }) ?? true else {
            return outcome(false, reason: .retiredEpoch, delivery: delivery, bytes: bytes)
        }
        return enqueue(delivery, bytes: bytes)
    }

    private func enqueue(_ delivery: GatewayEventDelivery, bytes: Int) -> GatewayEventAdmission {
        beginEvidence(for: delivery.connectionID)
        let byteCount = max(0, bytes)
        let key = coalescingKey(for: delivery)
        if byteCount > policy.maximumBytes {
            return outcome(false, reason: .oversizedEvent, delivery: delivery, bytes: byteCount)
        }
        if !waiters.isEmpty {
            let (_, waiter) = waiters.removeFirst()
            markDequeued(delivery)
            waiter.resume(returning: delivery)
            lastDequeuedAt = clock.now()
            admittedCount = admittedCount.saturatingIncremented()
            dequeuedCount = dequeuedCount.saturatingIncremented()
            return outcome(true, reason: nil, delivery: delivery, bytes: byteCount)
        }
        if let key, let index = buffered.lastIndex(where: { $0.key == key }) {
            let replacementBytes = bufferedBytes - buffered[index].bytes + byteCount
            guard replacementBytes <= policy.maximumBytes else {
                return outcome(false, reason: .byteLimit, delivery: delivery, bytes: byteCount)
            }
            bufferedBytes = replacementBytes
            buffered[index] = BufferedDelivery(
                delivery: delivery, bytes: byteCount, key: key,
                queuedAt: min(buffered[index].queuedAt, clock.now())
            )
            admittedCount = admittedCount.saturatingIncremented()
            updateHighWaterMarks()
            let pressureChanged = notePressure()
            return outcome(true, reason: nil, delivery: delivery, bytes: byteCount, pressureChanged: pressureChanged)
        }
        if buffered.count >= policy.maximumEvents {
            return outcome(false, reason: .countLimit, delivery: delivery, bytes: byteCount)
        }
        guard bufferedBytes <= policy.maximumBytes - byteCount else {
            return outcome(false, reason: .byteLimit, delivery: delivery, bytes: byteCount)
        }
        buffered.append(BufferedDelivery(
            delivery: delivery, bytes: byteCount, key: key, queuedAt: clock.now()
        ))
        bufferedBytes += byteCount
        admittedCount = admittedCount.saturatingIncremented()
        updateHighWaterMarks()
        let pressureChanged = notePressure()
        return outcome(true, reason: nil, delivery: delivery, bytes: byteCount, pressureChanged: pressureChanged)
    }

    func snapshot() -> GatewayEventHubSnapshot { makeSnapshot(now: clock.now()) }

    private func dequeue(_ value: BufferedDelivery) {
        buffered.removeFirst()
        bufferedBytes -= value.bytes
        lastDequeuedAt = clock.now()
        if value.delivery.connectionID == evidenceConnectionID {
            dequeuedCount = dequeuedCount.saturatingIncremented()
        }
    }

    private func outcome(
        _ accepted: Bool,
        reason: GatewayEventAdmissionReason?,
        delivery: GatewayEventDelivery,
        bytes: Int,
        pressureChanged: Bool = false
    ) -> GatewayEventAdmission {
        GatewayEventAdmission(
            accepted: accepted,
            reason: reason,
            topic: admittedTopic(delivery.event.topic),
            admittedBytes: max(0, bytes),
            snapshot: makeSnapshot(now: clock.now()),
            pressureChanged: pressureChanged
        )
    }

    private func makeSnapshot(now: ContinuousClock.Instant) -> GatewayEventHubSnapshot {
        GatewayEventHubSnapshot(
            bufferedEventCount: buffered.count,
            bufferedBytes: max(0, bufferedBytes),
            maximumEvents: policy.maximumEvents,
            maximumBytes: policy.maximumBytes,
            oldestQueuedAgeMilliseconds: buffered.first.map { milliseconds($0.queuedAt.duration(to: now)) } ?? 0,
            timeSinceLastDequeueMilliseconds: lastDequeuedAt.map { milliseconds($0.duration(to: now)) },
            countHighWaterMark: countHighWaterMark,
            byteHighWaterMark: byteHighWaterMark,
            admittedCount: admittedCount,
            dequeuedCount: dequeuedCount,
            pressureCrossings: pressureLevels.count,
            pressureLevels: pressureLevels.sorted(),
            dequeueWaitAgeMilliseconds: dequeuedAt.map { milliseconds($0.duration(to: now)) },
            dequeueWaitTopic: dequeuedTopic,
            dequeueWaitConnectionID: dequeuedConnectionID
        )
    }

    private func updateHighWaterMarks() {
        countHighWaterMark = max(countHighWaterMark, buffered.count)
        byteHighWaterMark = max(byteHighWaterMark, bufferedBytes)
    }

    private func notePressure() -> Bool {
        guard policy.maximumEvents > 0, policy.maximumBytes > 0 else { return false }
        let previousCount = pressureLevels.count
        let ratio = max(Double(buffered.count) / Double(policy.maximumEvents), Double(bufferedBytes) / Double(policy.maximumBytes))
        for level in [50, 75, 90, 100] where ratio >= Double(level) / 100 {
            pressureLevels.insert(level)
        }
        return pressureLevels.count > previousCount
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return Int(max(0, min(Int64(Int.max), value)))
    }

    private func admittedTopic(_ topic: String) -> String {
        GatewayDiagnosticTopicAdmission.admit(topic)
    }

    private func markDequeued(_ delivery: GatewayEventDelivery) {
        dequeuedAt = clock.now()
        dequeuedTopic = admittedTopic(delivery.event.topic)
        dequeuedConnectionID = delivery.connectionID
    }

    private func clearDequeued() {
        dequeuedAt = nil
        dequeuedTopic = nil
        dequeuedConnectionID = nil
    }

    private func beginEvidence(for connectionID: Int) {
        guard evidenceConnectionID != connectionID else { return }
        // A replacement epoch supersedes queued predecessor projections. This
        // runs before capacity checks; stale backlog cannot retire its successor.
        buffered.removeAll { $0.delivery.connectionID < connectionID }
        bufferedBytes = buffered.reduce(0) { $0 + $1.bytes }
        evidenceConnectionID = connectionID
        admittedCount = 0
        dequeuedCount = 0
        countHighWaterMark = 0
        byteHighWaterMark = 0
        pressureLevels.removeAll()
        lastDequeuedAt = nil
        clearDequeued()
    }

    private func coalescingKey(for delivery: GatewayEventDelivery) -> String? {
        let prefix = "connection:\(delivery.connectionID):"
        switch delivery.event.preparation {
        case .sessionSummary(let update): return "\(prefix)summary:\(update.sessionId)"
        case .none where delivery.event.topic == "session.listChanged": return "\(prefix)listChanged"
        case .notificationInboxChanged: return "\(prefix)notificationInboxChanged"
        case .none where delivery.event.topic == "notification.inbox.changed": return "\(prefix)notificationInboxChanged"
        case .none where delivery.event.topic == "devices.changed": return "\(prefix)devicesChanged"
        case .automationChanged: return "\(prefix)automationChanged"
        default: return nil
        }
    }

    func reset(connectionID: Int, notification: GatewayEvent? = nil) {
        let mayNotify = !finished && connectionID > retiredThrough
            && (evidenceConnectionID.map { connectionID >= $0 } ?? true)
        retiredThrough = max(retiredThrough, connectionID)
        buffered.removeAll { $0.delivery.connectionID <= retiredThrough }
        bufferedBytes = buffered.reduce(0) { $0 + $1.bytes }
        if let owner = evidenceConnectionID, owner <= retiredThrough {
            evidenceConnectionID = nil
            admittedCount = 0
            dequeuedCount = 0
            countHighWaterMark = buffered.count
            byteHighWaterMark = bufferedBytes
            pressureLevels.removeAll()
            lastDequeuedAt = nil
        }
        if let owner = dequeuedConnectionID, owner <= retiredThrough { clearDequeued() }
        // Only the retirement owner may enqueue its final control notification.
        // Ordinary frames remain fenced, including after the buffer is empty.
        if mayNotify, let notification {
            _ = enqueue(GatewayEventDelivery(connectionID: connectionID, event: notification), bytes: notification.admittedBytes)
        }
    }

    func finish() {
        finished = true
        buffered.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.1.resume(returning: nil) }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let (_, waiter) = waiters.remove(at: index)
        waiter.resume(returning: nil)
    }
}

private extension Int {
    func saturatingIncremented() -> Int { self == Int.max ? self : self + 1 }
}

package struct GatewayEventStream: AsyncSequence, Sendable {
    package typealias Element = GatewayEventDelivery

    fileprivate let hub: GatewayEventHub

    internal init(hub: GatewayEventHub) {
        self.hub = hub
    }

    package struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let hub: GatewayEventHub

        package mutating func next() async -> GatewayEventDelivery? {
            await hub.next()
        }
    }

    package func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(hub: hub)
    }

}
