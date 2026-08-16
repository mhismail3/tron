import Foundation

enum GatewayRequestTransmissionState: Equatable {
    case queued
    case sending
    case sent

    var mayHaveBeenSent: Bool { self != .queued }
}

actor GatewayClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
        var send: Task<Void, Never>?
        var transmission: GatewayRequestTransmissionState
    }

    private struct ConnectionEpoch {
        let id: Int
        let socket: any GatewaySocketConnection
        var receiveTask: Task<Void, Never>?
        var livenessTask: Task<Void, Never>?
        var pending: [String: PendingRequest] = [:]
        var lastInboundAt: ContinuousClock.Instant?
        var overflowResyncSignaled = false
        var info: GatewayInfo?
    }

    nonisolated let events: AsyncStream<GatewayEventDelivery>
    private let eventContinuation: AsyncStream<GatewayEventDelivery>.Continuation
    private let socketFactory: GatewaySocketFactory
    private let clock: MonotonicClock
    private let uuidSource: UUIDSource
    private let frameDecoder: GatewayFrameDecoder
    private let boundedHTTPDataTransport: BoundedHTTPDataTransport
    private let performanceSignposts: any PerformanceSignposting
    private var connection: ConnectionEpoch?
    private var generation = 0
    private var profile: GatewayProfile?
    private var token: String?

    var info: GatewayInfo? { connection?.info }

    init(
        socketFactory: GatewaySocketFactory = .urlSession,
        clock: MonotonicClock = .continuous,
        uuidSource: UUIDSource = .random,
        frameDecoder: GatewayFrameDecoder = .gateway,
        boundedHTTPDataTransport: BoundedHTTPDataTransport = .urlSession,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.socketFactory = socketFactory
        self.clock = clock
        self.uuidSource = uuidSource
        self.frameDecoder = frameDecoder
        self.boundedHTTPDataTransport = boundedHTTPDataTransport
        self.performanceSignposts = performanceSignposts
        var continuation: AsyncStream<GatewayEventDelivery>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation = $0 }
        eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
        connection?.receiveTask?.cancel()
        connection?.livenessTask?.cancel()
        if let socket = connection?.socket {
            Task { await socket.close() }
        }
    }

    func connect(profile: GatewayProfile, token: String) async throws -> GatewayInfo {
        try await establish(profile: profile, token: token, activateEvents: true).info
    }

    func connectForLifecycle(profile: GatewayProfile, token: String) async throws -> GatewayConnectionIdentity {
        try await establish(profile: profile, token: token, activateEvents: false)
    }

    private func establish(
        profile: GatewayProfile,
        token: String,
        activateEvents: Bool
    ) async throws -> GatewayConnectionIdentity {
        let interval = performanceSignposts.begin(.gatewayConnect)
        do {
            let identity = try await establishConnection(
                profile: profile,
                token: token,
                activateEvents: activateEvents
            )
            performanceSignposts.end(interval, result: .success, metrics: .none)
            return identity
        } catch {
            let result = PerformanceResult.forFailure(error)
            performanceSignposts.end(interval, result: result, metrics: .none)
            throw error
        }
    }

    private func establishConnection(
        profile: GatewayProfile,
        token: String,
        activateEvents: Bool
    ) async throws -> GatewayConnectionIdentity {
        generation &+= 1
        let epochID = generation
        await detachConnection(
            reason: GatewayFailure(code: "replaced", message: "Connection replaced", retryable: true, details: nil)
        )
        try Task.checkCancellation()
        guard generation == epochID else { throw CancellationError() }

        guard let socketURL = profile.socketURL else { throw Self.invalidProfileEndpoint() }
        self.profile = profile
        self.token = token
        var request = URLRequest(url: socketURL, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = socketFactory.makeConnection(request)
        connection = ConnectionEpoch(id: epochID, socket: socket)

        do {
            let hello: JSONValue = .object([
                "type": .string("hello"),
                "protocolVersion": .number(2),
                "clientId": .string(uuidSource.next().uuidString),
            ])
            try await socket.send(JSONEncoder.gateway.encode(hello))
            try requireEpoch(epochID)
            let data = try await withTimeout(duration: .seconds(15)) { try await socket.receive() }
            try requireEpoch(epochID)
            try GatewayFramePolicy.validateInboundBytes(data)
            let decoded = try JSONDecoder.gateway.decode(GatewayHello.self, from: data)
            try requireEpoch(epochID)
            guard decoded.type == "hello", decoded.protocolVersion == 2, decoded.minProtocolVersion <= 2 else {
                throw GatewayFailure(code: "protocol_mismatch", message: "The Mac gateway protocol is not compatible with this app.", retryable: false, details: nil)
            }
            guard var epoch = connection, epoch.id == epochID else { throw CancellationError() }
            epoch.info = decoded.info
            epoch.lastInboundAt = clock.now()
            connection = epoch
            if activateEvents {
                startReceive(epochID: epochID)
                startLivenessWait(epochID: epochID)
            }
            return GatewayConnectionIdentity(id: epochID, info: decoded.info)
        } catch {
            await detachConnection(epochID: epochID, reason: Self.transportFailure(error))
            throw error
        }
    }

    func reconnect() async throws -> GatewayInfo {
        try await reconnectForLifecycle(activateEvents: true).info
    }

    func reconnectForLifecycle(activateEvents: Bool = false) async throws -> GatewayConnectionIdentity {
        guard let profile, let token else {
            throw GatewayFailure(code: "not_paired", message: "No paired gateway is selected.", retryable: false, details: nil)
        }
        return try await establish(profile: profile, token: token, activateEvents: activateEvents)
    }

    func activateEvents(connectionID: Int) throws {
        try requireEpoch(connectionID)
        startReceive(epochID: connectionID)
        startLivenessWait(epochID: connectionID)
    }

    func close() async {
        generation &+= 1
        profile = nil
        token = nil
        await detachConnection(
            reason: GatewayFailure(code: "closed", message: "Connection closed", retryable: true, details: nil)
        )
    }

    func ensureResponsive(maximumSilence: Duration = .seconds(35)) async throws {
        guard let epoch = connection, let lastInboundAt = epoch.lastInboundAt else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        if clock.now() - lastInboundAt <= maximumSilence { return }
        struct Response: Decodable { let protocolVersion: Int }
        let _: Response = try await request(
            "system.info",
            EmptyParams(),
            timeout: .seconds(8),
            expectedEpochID: epoch.id
        )
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

    func requestValue<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        try await requestValue(method, params, timeout: timeout, expectedEpochID: nil)
    }

    private func request<P: Encodable, R: Decodable>(
        _ method: String,
        _ params: P,
        as responseType: R.Type = R.self,
        timeout: Duration,
        expectedEpochID: Int
    ) async throws -> R {
        let value = try await requestValue(
            method,
            params,
            timeout: timeout,
            expectedEpochID: expectedEpochID
        )
        return try value.decode(responseType)
    }

    private func requestValue<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration,
        expectedEpochID: Int?
    ) async throws -> JSONValue {
        guard let epoch = connection,
              expectedEpochID == nil || expectedEpochID == epoch.id else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        let epochID = epoch.id
        let socket = epoch.socket
        let id = uuidSource.next().uuidString
        let frame = GatewayRequest(id: id, method: method, params: try JSONValue.encode(params))
        let data = try JSONEncoder.gateway.encode(frame)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var current = connection, current.id == epochID else {
                    continuation.resume(throwing: GatewayFailure(
                        code: "replaced",
                        message: "Connection replaced",
                        retryable: true,
                        details: nil
                    ))
                    return
                }
                let clock = self.clock
                let timeoutTask = Task { [weak self] in
                    try? await clock.sleep(timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id: id, epochID: epochID)
                }
                current.pending[id] = PendingRequest(
                    continuation: continuation,
                    timeout: timeoutTask,
                    send: nil,
                    transmission: .queued
                )
                connection = current
                let sendTask = Task { [weak self, socket] in
                    guard await self?.claimSend(id: id, epochID: epochID) == true else { return }
                    let result: Result<Void, Error>
                    do {
                        try await socket.send(data)
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    await self?.sendCompleted(result, id: id, epochID: epochID)
                }
                guard var installedEpoch = connection,
                      installedEpoch.id == epochID,
                      var installedRequest = installedEpoch.pending[id] else {
                    sendTask.cancel()
                    return
                }
                installedRequest.send = sendTask
                installedEpoch.pending[id] = installedRequest
                connection = installedEpoch
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id, epochID: epochID) }
        }
    }

    private func claimSend(id: String, epochID: Int) -> Bool {
        guard var epoch = connection, epoch.id == epochID,
              var request = epoch.pending[id], request.transmission == .queued else { return false }
        request.transmission = .sending
        epoch.pending[id] = request
        connection = epoch
        return true
    }

    private func sendCompleted(
        _ result: Result<Void, Error>,
        id: String,
        epochID: Int
    ) {
        guard var epoch = connection, epoch.id == epochID,
              var request = epoch.pending[id] else { return }
        switch result {
        case .success:
            request.transmission = .sent
            epoch.pending[id] = request
            connection = epoch
        case .failure(let error):
            fail(
                id: id,
                epochID: epochID,
                error: Self.possiblySentFailure(cause: error)
            )
        }
    }

    func upload(name: String, mimeType: String, data: Data) async throws -> String {
        guard let profile, let token else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        guard let url = profile.httpURL(
            path: "/v1/uploads",
            queryItems: [URLQueryItem(name: "name", value: name)]
        ) else { throw Self.invalidProfileEndpoint() }
        var request = URLRequest(url: url, timeoutInterval: 60)
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

    func blob(id: String, maximumBytes: Int) async throws -> (Data, String) {
        guard let profile, let token, let connectionID = connection?.id else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        let value = try await boundedBlob(
            id: id,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        try requireEpoch(connectionID)
        guard self.profile?.id == profile.id else { throw CancellationError() }
        return value
    }

    func blob(
        id: String,
        profileID: String,
        connectionID: Int,
        maximumBytes: Int
    ) async throws -> (Data, String) {
        guard let profile, profile.id == profileID,
              let token, connection?.id == connectionID else {
            throw CancellationError()
        }
        let value = try await boundedBlob(
            id: id,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        try requireEpoch(connectionID)
        guard self.profile?.id == profileID else { throw CancellationError() }
        return value
    }

    private func boundedBlob(
        id: String,
        profile: GatewayProfile,
        token: String,
        maximumBytes: Int
    ) async throws -> (Data, String) {
        guard let url = profile.httpURL(path: "/v1/blobs/\(id)") else {
            throw Self.invalidProfileEndpoint()
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await boundedHTTPDataTransport.data(
            for: request,
            maximumBytes: maximumBytes
        )
        guard http.statusCode == 200 else {
            throw GatewayFailure(code: "blob_failed", message: "The image is no longer available. Refresh the session.", retryable: true, details: nil)
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    private func startReceive(epochID: Int) {
        guard var epoch = connection, epoch.id == epochID else { return }
        let socket = epoch.socket
        epoch.receiveTask = Task { [weak self, socket] in
            let result: Result<Data, Error>
            do { result = .success(try await socket.receive()) }
            catch { result = .failure(error) }
            await self?.receiveCompleted(result, epochID: epochID)
        }
        connection = epoch
    }

    private func receiveCompleted(_ result: Result<Data, Error>, epochID: Int) async {
        guard ownsEpoch(epochID) else { return }
        switch result {
        case .success(let data):
            guard var current = connection, current.id == epochID else { return }
            current.lastInboundAt = clock.now()
            connection = current
            do {
                try await handle(data, epochID: epochID)
                if ownsEpoch(epochID) { startReceive(epochID: epochID) }
            } catch {
                await disconnectEpoch(epochID: epochID, failure: Self.transportFailure(error))
            }
        case .failure(let error):
            await disconnectEpoch(epochID: epochID, failure: Self.transportFailure(error))
        }
    }

    private func startLivenessWait(epochID: Int) {
        guard var epoch = connection, epoch.id == epochID else { return }
        let clock = self.clock
        epoch.livenessTask = Task { [weak self, clock] in
            do { try await clock.sleep(.seconds(20)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.livenessWaitCompleted(epochID: epochID)
        }
        connection = epoch
    }

    private func livenessWaitCompleted(epochID: Int) async {
        guard ownsEpoch(epochID) else { return }
        do {
            guard let lastInboundAt = connection?.lastInboundAt else { return }
            if clock.now() - lastInboundAt > .seconds(35) {
                struct Response: Decodable { let protocolVersion: Int }
                let _: Response = try await request(
                    "system.info",
                    EmptyParams(),
                    timeout: .seconds(8),
                    expectedEpochID: epochID
                )
            }
            if ownsEpoch(epochID) { startLivenessWait(epochID: epochID) }
        } catch {
            guard ownsEpoch(epochID) else { return }
            await disconnectEpoch(epochID: epochID, failure: Self.transportFailure(error))
        }
    }

    private func disconnectEpoch(epochID: Int, failure: GatewayFailure) async {
        guard await detachConnection(epochID: epochID, reason: failure) else { return }
        eventContinuation.yield(GatewayEventDelivery(
            connectionID: epochID,
            event: GatewayEvent(
                type: "event",
                topic: "transport.disconnected",
                sessionId: nil,
                payload: .object(["message": .string(failure.message)])
            )
        ))
    }

    private func handle(_ data: Data, epochID: Int) async throws {
        try requireEpoch(epochID)
        let frame = try frameDecoder.decode(data)
        try requireEpoch(epochID)
        switch frame {
        case .response(let response):
            guard let waiter = removePending(id: response.id, epochID: epochID) else { return }
            if response.ok {
                waiter.continuation.resume(returning: response.result ?? .null)
            } else {
                waiter.continuation.resume(throwing: response.error ?? GatewayFailure(
                    code: "invalid_response",
                    message: "Gateway returned an invalid error.",
                    retryable: false,
                    details: nil
                ))
            }
        case .event(let event):
            if case .dropped = eventContinuation.yield(GatewayEventDelivery(
                connectionID: epochID,
                event: event
            )) {
                guard var current = connection,
                      current.id == epochID,
                      !current.overflowResyncSignaled else { return }
                current.overflowResyncSignaled = true
                connection = current
                await disconnectEpoch(
                    epochID: epochID,
                    failure: GatewayFailure(
                        code: "event_overflow",
                        message: "Live event buffer overflow",
                        retryable: true,
                        details: nil
                    )
                )
            }
        case .unsupported:
            break
        }
    }

    private func expire(id: String, epochID: Int) {
        guard let epoch = connection, epoch.id == epochID,
              let request = epoch.pending[id] else { return }
        let error: Error = request.transmission.mayHaveBeenSent
            ? Self.possiblySentFailure(message: "The Mac did not answer after the request may have been sent.")
            : GatewayFailure(code: "timeout", message: "The request expired before it was sent.", retryable: true, details: nil)
        fail(id: id, epochID: epochID, error: error)
    }

    private func cancelRequest(id: String, epochID: Int) {
        guard let epoch = connection, epoch.id == epochID,
              let request = epoch.pending[id] else { return }
        let error: Error = request.transmission.mayHaveBeenSent
            ? Self.possiblySentFailure(message: "The cancelled request may have reached the Mac.")
            : CancellationError()
        fail(id: id, epochID: epochID, error: error)
    }

    private func fail(id: String, epochID: Int, error: Error) {
        guard let waiter = removePending(id: id, epochID: epochID) else { return }
        waiter.continuation.resume(throwing: error)
    }

    private func removePending(id: String, epochID: Int) -> PendingRequest? {
        guard var epoch = connection, epoch.id == epochID,
              let waiter = epoch.pending.removeValue(forKey: id) else { return nil }
        connection = epoch
        waiter.timeout.cancel()
        waiter.send?.cancel()
        return waiter
    }

    @discardableResult
    private func detachConnection(epochID: Int? = nil, reason: Error) async -> Bool {
        guard let epoch = connection,
              epochID == nil || epoch.id == epochID else { return false }
        connection = nil
        epoch.receiveTask?.cancel()
        epoch.livenessTask?.cancel()
        for waiter in epoch.pending.values {
            waiter.timeout.cancel()
            waiter.send?.cancel()
            waiter.continuation.resume(throwing: waiter.transmission.mayHaveBeenSent
                ? Self.possiblySentFailure(cause: reason)
                : reason)
        }
        await epoch.socket.close()
        return generation == epoch.id && connection == nil
    }

    private func ownsEpoch(_ epochID: Int) -> Bool {
        connection?.id == epochID
    }

    private func requireEpoch(_ epochID: Int) throws {
        guard ownsEpoch(epochID) else { throw CancellationError() }
    }

    private nonisolated static func invalidProfileEndpoint() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_profile",
            message: "This saved gateway address is invalid. Pair the Mac again.",
            retryable: false,
            details: nil
        )
    }

    private nonisolated static func possiblySentFailure(
        message: String = "The request may have reached the Mac before the connection ended.",
        cause: Error? = nil
    ) -> GatewayPossiblySentError {
        GatewayPossiblySentError(failure: GatewayFailure(
            code: "possibly_sent",
            message: message,
            retryable: true,
            details: cause.map { .object(["cause": .string(transportFailure($0).code)]) }
        ))
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
