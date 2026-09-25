import Foundation
import TronComputerControl

struct NativeCaptureHostFrame: Sendable {
    let generation: UUID
    let sequence: UInt64
    let jpeg: Data
    let width: Int
    let height: Int
}
struct NativeCaptureRetirement: Sendable {
    let joined: Bool
    let diagnostic: String?
}
protocol NativeCaptureProducing: Sendable {
    func start() async -> NativeWindowCaptureAvailability
    func take(generation: UUID) throws -> NativeCaptureHostFrame?
    func requestStop()
    func join() async -> NativeCaptureRetirement
}
extension NativeCaptureStream: NativeCaptureProducing {
    func take(generation: UUID) throws -> NativeCaptureHostFrame? {
        try takeLatestFrame(generation: generation).map {
            NativeCaptureHostFrame(generation: $0.generation, sequence: $0.sequence, jpeg: $0.jpeg, width: $0.width, height: $0.height)
        }
    }
    func join() async -> NativeCaptureRetirement {
        let result = await stopAndJoin()
        return NativeCaptureRetirement(joined: result == .joined, diagnostic: retirementFailure.map { String(describing: $0) })
    }
}
struct NativeCaptureTarget: Sendable {
    let kind: NativeCaptureSource.Kind
    let applicationName: String
    let title: String
    let width: Double
    let height: Double
    let make: @Sendable (NativeCaptureRegion?, @escaping @Sendable () -> Bool) throws -> any NativeCaptureProducing
}
struct NativeCaptureOperations: Sendable {
    let validate: @Sendable () async -> Bool
    let catalog: @Sendable (@escaping @Sendable () -> Bool) async throws -> [NativeCaptureTarget]
    let automationEndpoint: @Sendable () -> NativeAutomationEndpoint?
    var now: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    var waitUntil: @Sendable (UInt64) async throws -> Void = { deadline in
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
    }
    static func live(peer: NativeCapturePeer, automationEndpoint: @escaping @Sendable () -> NativeAutomationEndpoint?) -> Self {
        Self(validate: { await peer.validate() }, catalog: { admission in
            try await NativeCaptureCatalog.load(admission: admission).map { source in
                NativeCaptureTarget(kind: source.kind, applicationName: source.applicationName, title: source.title,
                                    width: source.width, height: source.height,
                                    make: { try source.makeStream(region: $0, admission: $1) })
            }
        }, automationEndpoint: automationEndpoint)
    }
}

/// Invalidations synchronously fence native callbacks even while the actor is
/// awaiting selection/start. Stop does not depend on a caller's Task surviving.
final class NativeCaptureFence: @unchecked Sendable {
    private let lock = NSLock()
    private enum State { case open, producerStopped, revoked }
    private var state = State.open
    private var producer: (any NativeCaptureProducing)?
    private let current: @Sendable () -> Bool
    init(current: @escaping @Sendable () -> Bool) { self.current = current }
    func admits() -> Bool {
        guard lock.withLock({ state == .open }) else { return false }
        guard current() else { close(); return false }
        return lock.withLock { state == .open }
    }
    func install(_ producer: any NativeCaptureProducing) {
        let stopped = lock.withLock { self.producer = producer; return state != .open }
        if stopped { producer.requestStop() }
    }
    /// Producer failure closes pixel admission, not the authenticated request's
    /// right to receive its finite terminal error after native cleanup joins.
    func stopProducer() {
        let producer = lock.withLock { if state == .open { state = .producerStopped }; return self.producer }
        producer?.requestStop()
    }
    func admitsFailureReply() -> Bool {
        guard current() else { close(); return false }
        return lock.withLock { state != .revoked }
    }
    func close() {
        let producer = lock.withLock { state = .revoked; return self.producer }
        producer?.requestStop()
    }
    func releaseJoinedProducer() { lock.withLock { producer = nil } }
}

/// One connection/session retains the exact selected target, independently of
/// visibility-owned streams. A fresh stream is allowed only after a clean suspend
/// join; uncertain retirement never enables resume or releases the global slot.
actor NativeCaptureSession {
    let bootID: UUID
    let connectionID = UUID()
    let sessionID = UUID()
    nonisolated let fence: NativeCaptureFence
    private let operations: NativeCaptureOperations
    private let slot: NativeCaptureSlot
    private let ownerID: UUID
    private var ownsStream = false
    private var demandTask: Task<Void, Never>?
    private var demandID = UUID()
    private var loadID: UUID?
    private var targets: [UUID: NativeCaptureTarget] = [:]
    private struct Selection: Equatable { let handle: UUID; let region: NativeCaptureRegion? }
    private var selection: Selection?
    private var catalogued = false
    private var producer: (any NativeCaptureProducing)?
    private var generation: UUID?
    private var lastRead: UInt64 = 0
    private var usedStream = false
    private var closed = false
    private var receiptCount = 0
    private var receipts: [UUID: (NativeCaptureRequest, Task<NativeCaptureResponse, Never>)] = [:]
    private var pending: Task<NativeCaptureResponse, Never>?
    private var retirement: Task<NativeCaptureRetirement, Never>?
    private var suspension: Task<NativeCaptureResponse, Never>?
    private var suspending = false

    init(bootID: UUID, ownerID: UUID, slot: NativeCaptureSlot, fence: NativeCaptureFence, operations: NativeCaptureOperations) {
        self.bootID = bootID; self.ownerID = ownerID; self.slot = slot
        self.fence = fence; self.operations = operations
    }

    func execute(_ request: NativeCaptureRequest) async -> NativeCaptureResponse {
        guard request.operation == "pull" ? request.commandID == nil : request.commandID != nil else { return .error(.invalidRequest) }
        if let commandID = request.commandID, let prior = receipts[commandID] {
            guard prior.0 == request else { return .error(.invalidRequest) }
            return await prior.1.value
        }
        guard request.operation == "hello" ? loadID == nil : matches(request) else { return .error(.stale) }
        if request.operation == "stop" {
            guard receiptCount < 64 else { return .error(.exhausted) }
            // Stop is eligible during every awaited phase. It cannot free the
            // slot until the pending native work and its exact producer join.
            closed = true; fence.close()
            let task = Task { [self] in
                let result = await drain()
                return response(request, status: result.joined ? "joined" : "retirementFailed",
                                fields: result.diagnostic.map { ["diagnostic": $0] } ?? [:])
            }
            receipts[request.commandID!] = (request, task); receiptCount += 1
            return await task.value
        }
        guard !closed, fence.admits() else { return .error(.stale) }
        if request.operation == "suspend" {
            guard !suspending, receiptCount < 63 else { return .error(.busy) }
            receiptCount += 1; suspending = true
            demandTask?.cancel(); demandTask = nil; demandID = UUID()
            producer?.requestStop()
            let pending = pending
            let task = Task { [self] in
                if let pending { _ = await pending.value }
                let result = await finishRetirement()
                if result.joined, result.diagnostic == nil, !closed {
                    // Keep only the original selected capability. No catalog
                    // lookup or window/PID/title resolution occurs on resume.
                    generation = nil; usedStream = false; retiredResult = nil
                } else {
                    closed = true; fence.close(); targets.removeAll()
                }
                suspending = false
                return response(request, status: result.joined ? "joined" : "retirementFailed",
                                fields: result.diagnostic.map { ["diagnostic": $0] } ?? [:])
            }
            suspension = task; receipts[request.commandID!] = (request, task)
            return await task.value
        }
        guard !suspending else { return .error(.stale) }
        guard pending == nil else { return .error(.busy) }
        if request.operation == "pull" {
            guard request.readSequence! > lastRead else { return .error(.stale) }
            lastRead = request.readSequence!
        } else {
            guard receiptCount < 63 else { return .error(.exhausted) } // Reserve Stop.
            receiptCount += 1
        }
        if request.operation == "hello" { loadID = request.loadID }
        let task = Task { [self] in await perform(request) }
        pending = task
        if let commandID = request.commandID { receipts[commandID] = (request, task) }
        let result = await task.value
        pending = nil
        // Replayed command receipts are control only. Pixels are never retained
        // in a receipt; each pull consumes one latest frame once.
        return result
    }

    private func matches(_ request: NativeCaptureRequest) -> Bool {
        request.bootID == bootID && request.connectionID == connectionID
            && request.sessionID == sessionID && request.loadID == loadID
    }
    private func admitted(_ request: NativeCaptureRequest) async -> Bool {
        guard !suspending, !closed, fence.admits(), request.loadID == loadID else { return false }
        guard await operations.validate(), !closed, fence.admits(), request.loadID == loadID else {
            closed = true; fence.close(); return false
        }
        return !suspending
    }
    private func perform(_ request: NativeCaptureRequest) async -> NativeCaptureResponse {
        defer { if closed { Task { [self] in _ = await drain() } } }
        guard await admitted(request), !suspending else { return .error(.unauthorized) }
        do {
            switch request.operation {
            case "hello": return response(request, status: "ready")
            case "automationEndpoint":
                guard let endpoint = operations.automationEndpoint() else { return .error(.unavailable) }
                return response(request, status: "automationEndpoint", fields: [
                    "socket": endpoint.socket, "generation": endpoint.generation.uuidString,
                ])
            case "catalog":
                guard !catalogued, !usedStream else { return .error(.stale) }
                catalogued = true
                let values = try await operations.catalog { [fence] in fence.admits() }
                guard await admitted(request), values.count <= NativeCaptureCatalog.maximumSources else { return .error(.stale) }
                var entries: [[String: Any]] = []
                for value in values {
                    let handle = UUID(); targets[handle] = value
                    entries.append(["handle": handle.uuidString, "kind": value.kind.rawValue,
                                    "width": value.width, "height": value.height,
                                    "applicationName": NativeCaptureText.bounded(value.applicationName), "title": NativeCaptureText.bounded(value.title)])
                }
                return response(request, status: "catalog", fields: ["sources": entries])
            case "start":
                guard !usedStream, let target = targets[request.handle!] else { return .error(.stale) }
                let requested = Selection(handle: request.handle!, region: request.region)
                guard selection == nil || selection == requested else { return .error(.stale) }
                if let region = request.region {
                    guard target.kind == .display,
                          (try? region.rectangle(in: CGSize(width: target.width, height: target.height))) != nil else { return .error(.invalidRequest) }
                }
                guard slot.reserveStream(ownerID) else { return .error(.busy) }
                ownsStream = true; usedStream = true; targets = [request.handle!: target]; selection = requested
                renewDemand()
                let created = try target.make(request.region) { [fence] in fence.admits() }
                producer = created; fence.install(created)
                let result = await created.start()
                guard await admitted(request), case let .available(id) = result else {
                    if suspending { return .error(.stale) }
                    closed = true; fence.stopProducer()
                    // Do not call drain from pending work: drain joins this task.
                    _ = await finishRetirement()
                    if case let .unavailable(reason) = result { return .error(.capture(reason)) }
                    return .error(.stale)
                }
                generation = id
                return response(request, status: "started", fields: ["generation": id.uuidString])
            case "pull":
                guard let producer, let generation, request.generation == generation else { return .error(.stale) }
                let frame = try producer.take(generation: generation)
                guard await admitted(request) else { return .error(.stale) }
                renewDemand()
                guard let frame else { return response(request, status: "empty", fields: ["readSequence": request.readSequence!]) }
                guard frame.generation == generation, !frame.jpeg.isEmpty, frame.jpeg.count <= 2 * 1_024 * 1_024,
                      (1...1280).contains(frame.width), (1...1280).contains(frame.height) else { throw NativeCaptureHostError.unavailable }
                return response(request, status: "frame", fields: ["generation": generation.uuidString,
                    "readSequence": request.readSequence!, "sequence": String(frame.sequence), "width": frame.width, "height": frame.height], jpeg: frame.jpeg)
            default: return .error(.invalidRequest)
            }
        } catch {
            closed = true; fence.stopProducer()
            _ = await finishRetirement()
            return .error(.capture(error))
        }
    }

    func drain() async -> NativeCaptureRetirement {
        if let retirement { return await retirement.value }
        closed = true; fence.stopProducer(); targets.removeAll(); demandTask?.cancel(); demandTask = nil
        let pending = pending
        let suspension = suspension
        let task = Task { [self] in
            if let pending { _ = await pending.value }
            if let suspension { _ = await suspension.value }
            return await finishRetirement()
        }
        retirement = task
        return await task.value
    }
    private var retiredResult: NativeCaptureRetirement?
    private func finishRetirement() async -> NativeCaptureRetirement {
        if let retiredResult { return retiredResult }
        let result = await producer?.join() ?? NativeCaptureRetirement(joined: true, diagnostic: nil)
        retiredResult = result
        if result.joined {
            self.producer = nil; fence.releaseJoinedProducer()
            if ownsStream { slot.releaseStream(ownerID); ownsStream = false }
        }
        return result
    }
    private func renewDemand() {
        demandTask?.cancel()
        let id = UUID(); demandID = id
        let deadline = operations.now() + 15_000_000_000
        demandTask = Task { [weak self, operations] in
            do { try await operations.waitUntil(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.expireDemand(id)
        }
    }
    private func expireDemand(_ id: UUID) async {
        guard demandID == id, !closed else { return }
        closed = true; fence.close()
        _ = await drain() // Expiry requests Stop; only actual retirement frees capacity.
    }
    private func response(_ request: NativeCaptureRequest, status: String, fields: [String: Any] = [:], jpeg: Data? = nil) -> NativeCaptureResponse {
        var object: [String: Any] = ["version": 1, "status": status,
            "bootID": bootID.uuidString, "connectionID": connectionID.uuidString, "sessionID": sessionID.uuidString, "loadID": request.loadID.uuidString]
        if let commandID = request.commandID { object["commandID"] = commandID.uuidString }
        object.merge(fields) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count <= 65_536 else { return .error(.unavailable) }
        return NativeCaptureResponse(control: data, jpeg: jpeg)
    }
}
