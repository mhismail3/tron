import Foundation

actor GatewayClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }

    nonisolated let events: AsyncStream<GatewayEvent>
    private let eventContinuation: AsyncStream<GatewayEvent>.Continuation
    private let socketFactory: GatewaySocketFactory
    private let clock: MonotonicClock
    private let uuidSource: UUIDSource
    private var socket: (any GatewaySocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var pending: [String: PendingRequest] = [:]
    private var processingInboundFrame = false
    private var inboundFrames: [Data] = []
    private var generation = 0
    private var intentionalDisconnectGenerations: Set<Int> = []
    private var lastInboundAt: ContinuousClock.Instant?
    private var overflowResyncSignaled = false
    private(set) var info: GatewayInfo?
    private var profile: GatewayProfile?
    private var token: String?

    init(
        socketFactory: GatewaySocketFactory = .urlSession,
        clock: MonotonicClock = .continuous,
        uuidSource: UUIDSource = .random
    ) {
        self.socketFactory = socketFactory
        self.clock = clock
        self.uuidSource = uuidSource
        var continuation: AsyncStream<GatewayEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation = $0 }
        eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
        receiveTask?.cancel()
        livenessTask?.cancel()
        if let socket {
            Task { await socket.close() }
        }
    }

    func connect(profile: GatewayProfile, token: String) async throws -> GatewayInfo {
        await disconnect(
            reason: GatewayFailure(code: "replaced", message: "Connection replaced", retryable: true, details: nil),
            intentional: true
        )
        self.profile = profile
        self.token = token
        generation &+= 1
        let currentGeneration = generation

        var request = URLRequest(url: profile.socketURL, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = socketFactory.makeConnection(request)
        self.socket = socket

        let hello: JSONValue = .object([
            "type": .string("hello"),
            "protocolVersion": .number(2),
            "clientId": .string(uuidSource.next().uuidString),
        ])
        try await socket.send(JSONEncoder.gateway.encode(hello))
        let data = try await withTimeout(duration: .seconds(15)) { try await socket.receive() }
        let decoded = try JSONDecoder.gateway.decode(GatewayHello.self, from: data)
        guard decoded.type == "hello", decoded.protocolVersion == 2, decoded.minProtocolVersion <= 2 else {
            throw GatewayFailure(code: "protocol_mismatch", message: "The Mac gateway protocol is not compatible with this app.", retryable: false, details: nil)
        }
        let info = decoded.info
        self.info = info
        lastInboundAt = clock.now()
        overflowResyncSignaled = false
        receiveTask = Task { [weak self] in await self?.receiveLoop(generation: currentGeneration) }
        livenessTask = Task { [weak self] in await self?.monitorLiveness(generation: currentGeneration) }
        return info
    }

    func reconnect() async throws -> GatewayInfo {
        guard let profile, let token else {
            throw GatewayFailure(code: "not_paired", message: "No paired gateway is selected.", retryable: false, details: nil)
        }
        return try await connect(profile: profile, token: token)
    }

    func close() async {
        profile = nil
        token = nil
        await disconnect(
            reason: GatewayFailure(code: "closed", message: "Connection closed", retryable: true, details: nil),
            intentional: true
        )
    }

    func ensureResponsive(maximumSilence: Duration = .seconds(35)) async throws {
        guard socket != nil, let lastInboundAt else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        if clock.now() - lastInboundAt <= maximumSilence { return }
        struct Response: Decodable { let protocolVersion: Int }
        let _: Response = try await request("system.info", EmptyParams(), timeout: .seconds(8))
    }

    func request<P: Encodable, R: Decodable>(
        _ method: String,
        _ params: P,
        as responseType: R.Type = R.self,
        timeout: Duration = .seconds(30)
    ) async throws -> R {
        let value = try await requestValue(method, params, timeout: timeout)
        return try value.decode(responseType)
    }

    func requestValue<P: Encodable>(_ method: String, _ params: P, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard let socket else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        let id = uuidSource.next().uuidString
        let frame = GatewayRequest(id: id, method: method, params: try JSONValue.encode(params))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let clock = self.clock
                let timeoutTask = Task { [weak self] in
                    try? await clock.sleep(timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id: id)
                }
                pending[id] = PendingRequest(continuation: continuation, timeout: timeoutTask)
                Task {
                    do {
                        try await socket.send(JSONEncoder.gateway.encode(frame))
                    } catch {
                        fail(id: id, error: Self.transportFailure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id: id, error: CancellationError()) }
        }
    }

    func upload(name: String, mimeType: String, data: Data) async throws -> String {
        guard let profile, let token else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        var components = URLComponents(url: profile.httpBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/uploads"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            throw GatewayFailure(code: "upload_failed", message: "The attachment could not be uploaded.", retryable: true, details: nil)
        }
        struct Envelope: Decodable { struct Upload: Decodable { let id: String }; let upload: Upload }
        return try JSONDecoder.gateway.decode(Envelope.self, from: responseData).upload.id
    }

    func blob(id: String) async throws -> (Data, String) {
        guard let profile, let token else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        var components = URLComponents(url: profile.httpBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/blobs/\(id)"
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GatewayFailure(code: "blob_failed", message: "The image is no longer available. Refresh the session.", retryable: true, details: nil)
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    private func receiveLoop(generation expected: Int) async {
        while !Task.isCancelled, generation == expected, let socket {
            do {
                let data = try await socket.receive()
                lastInboundAt = clock.now()
                await enqueue(data)
            } catch {
                let intentional = intentionalDisconnectGenerations.remove(expected) != nil
                guard generation == expected, !intentional, !(error is CancellationError) else { return }
                let failure = Self.transportFailure(error)
                await disconnect(reason: failure)
                eventContinuation.yield(GatewayEvent(
                    type: "event",
                    topic: "transport.disconnected",
                    sessionId: nil,
                    payload: .object(["message": .string(failure.message)])
                ))
                return
            }
        }
    }

    private func monitorLiveness(generation expected: Int) async {
        while !Task.isCancelled, generation == expected, socket != nil {
            try? await clock.sleep(.seconds(20))
            guard !Task.isCancelled, generation == expected, socket != nil else { return }
            do {
                try await ensureResponsive(maximumSilence: .seconds(35))
            } catch {
                guard generation == expected else { return }
                let failure = Self.transportFailure(error)
                await disconnect(reason: failure)
                eventContinuation.yield(GatewayEvent(
                    type: "event",
                    topic: "transport.disconnected",
                    sessionId: nil,
                    payload: .object(["message": .string(failure.message)])
                ))
                return
            }
        }
    }

    private func enqueue(_ data: Data) async {
        inboundFrames.append(data)
        await drainInboundFrames()
    }

    private func drainInboundFrames() async {
        guard !processingInboundFrame else { return }
        processingInboundFrame = true
        defer { processingInboundFrame = false }
        while !inboundFrames.isEmpty {
            let data = inboundFrames.removeFirst()
            do { try await handle(data) }
            catch {
                let failure = Self.transportFailure(error)
                await disconnect(reason: failure)
                eventContinuation.yield(GatewayEvent(
                    type: "event",
                    topic: "transport.disconnected",
                    sessionId: nil,
                    payload: .object(["message": .string(failure.message)])
                ))
                return
            }
        }
    }

    private func handle(_ data: Data) async throws {
        let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let object = value.objectValue, let type = object["type"]?.stringValue else { return }
        switch type {
        case "response":
            let response = try JSONDecoder.gateway.decode(GatewayResponse.self, from: data)
            guard let waiter = pending.removeValue(forKey: response.id) else { return }
            waiter.timeout.cancel()
            if response.ok { waiter.continuation.resume(returning: response.result ?? .null) }
            else { waiter.continuation.resume(throwing: response.error ?? GatewayFailure(code: "invalid_response", message: "Gateway returned an invalid error.", retryable: false, details: nil)) }
        case "event":
            let event = try JSONDecoder.gateway.decode(GatewayEvent.self, from: data)
            if case .dropped = eventContinuation.yield(event), !overflowResyncSignaled {
                overflowResyncSignaled = true
                await disconnect(reason: GatewayFailure(
                    code: "event_overflow",
                    message: "The live event buffer overflowed; reconnecting for an authoritative snapshot.",
                    retryable: true,
                    details: nil
                ))
                _ = eventContinuation.yield(GatewayEvent(
                    type: "event",
                    topic: "transport.disconnected",
                    sessionId: nil,
                    payload: .object(["message": .string("Live event buffer overflow")])
                ))
            }
        default:
            break
        }
    }

    private func expire(id: String) {
        fail(id: id, error: GatewayFailure(code: "timeout", message: "The Mac did not answer in time.", retryable: true, details: nil))
    }

    private func fail(id: String, error: Error) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func disconnect(reason: Error, intentional: Bool = false) async {
        if intentional, receiveTask != nil { intentionalDisconnectGenerations.insert(generation) }
        receiveTask?.cancel()
        receiveTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        let closingSocket = socket
        socket = nil
        info = nil
        lastInboundAt = nil
        overflowResyncSignaled = false
        let waiters = pending.values
        pending.removeAll()
        inboundFrames.removeAll()
        for waiter in waiters {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: reason)
        }
        await closingSocket?.close()
    }

    private nonisolated static func transportFailure(_ error: Error) -> GatewayFailure {
        if let failure = error as? GatewayFailure { return failure }
        return GatewayFailure(code: "disconnected", message: error.localizedDescription, retryable: true, details: nil)
    }

    private func withTimeout<T: Sendable>(
        duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = self.clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(duration)
                throw GatewayFailure(code: "timeout", message: "The Mac gateway did not complete its handshake.", retryable: true, details: nil)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
