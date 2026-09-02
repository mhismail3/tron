import Foundation

enum GatewayRequestTransmissionState: Equatable {
    case queued
    case sending
    case sent

    var mayHaveBeenSent: Bool { self != .queued }
}

enum GatewayUploadPolicy {
    static let maximumRequestBytes = 25 * 1_048_576
    static let maximumResponseBytes = 64 * 1_024
}

enum GatewayLivenessPolicy {
    /// Transport pings run independently of GatewayClient actor/event work so a
    /// busy live stream cannot starve the proof required by the server heartbeat.
    static let probeInterval: Duration = .seconds(10)
}

struct GatewayEventBufferPolicy: Sendable {
    let maximumEvents: Int
    let maximumBytes: Int

    // Matches the Gateway synchronization quarantine count while the byte cap
    // remains the stricter cross-session memory bound.
    static let `default` = Self(maximumEvents: 1_024, maximumBytes: 2 * 1_024 * 1_024)
}

private actor GatewayEventHub {
    private struct BufferedDelivery {
        let delivery: GatewayEventDelivery
        let bytes: Int
        let key: String?
    }

    private let policy: GatewayEventBufferPolicy
    private var buffered: [BufferedDelivery] = []
    private var bufferedBytes = 0
    private var waiters: [(UUID, CheckedContinuation<GatewayEventDelivery?, Never>)] = []
    private var finished = false

    init(policy: GatewayEventBufferPolicy = .default) {
        self.policy = policy
    }

    func next() async -> GatewayEventDelivery? {
        if let first = buffered.first {
            buffered.removeFirst()
            bufferedBytes -= first.bytes
            return first.delivery
        }
        if finished || Task.isCancelled { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let first = buffered.first {
                    buffered.removeFirst()
                    bufferedBytes -= first.bytes
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

    /// Returns true when preserving the ordered event would exceed a hard
    /// bound. The caller must retire the epoch and rebaseline; it never drops a
    /// sequenced event silently.
    func yield(_ delivery: GatewayEventDelivery, bytes: Int) -> Bool {
        guard !finished else { return false }
        if !waiters.isEmpty {
            let (_, waiter) = waiters.removeFirst()
            waiter.resume(returning: delivery)
            return false
        }
        let byteCount = max(0, bytes)
        let key = coalescingKey(for: delivery)
        if let key, let index = buffered.lastIndex(where: { $0.key == key }) {
            bufferedBytes += byteCount - buffered[index].bytes
            buffered[index] = BufferedDelivery(delivery: delivery, bytes: byteCount, key: key)
            return bufferedBytes > policy.maximumBytes
        }
        guard buffered.count < policy.maximumEvents,
              byteCount <= policy.maximumBytes,
              bufferedBytes <= policy.maximumBytes - byteCount else { return true }
        buffered.append(BufferedDelivery(delivery: delivery, bytes: byteCount, key: key))
        bufferedBytes += byteCount
        return false
    }

    private func coalescingKey(for delivery: GatewayEventDelivery) -> String? {
        switch delivery.event.preparation {
        case .sessionSummary(let update): return "summary:\(update.sessionId)"
        case .none where delivery.event.topic == "session.listChanged": return "listChanged"
        case .none where delivery.event.topic == "notification.inbox.changed": return "notificationInboxChanged"
        default: return nil
        }
    }

    func reset(connectionID: Int) {
        let retained = buffered.filter { $0.delivery.connectionID != connectionID }
        bufferedBytes = retained.reduce(0) { $0 + $1.bytes }
        buffered = retained
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

struct GatewayEventStream: AsyncSequence, Sendable {
    typealias Element = GatewayEventDelivery

    fileprivate let hub: GatewayEventHub

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let hub: GatewayEventHub

        mutating func next() async -> GatewayEventDelivery? {
            await hub.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(hub: hub)
    }
}

enum GatewayResponseDecoding {
    private static let maximumMethodCharacters = 160
    private static let maximumPathCharacters = 512
    private static let maximumPathComponents = 64

    static func decode<Response: Decodable>(
        _ value: JSONValue,
        as responseType: Response.Type,
        method: String
    ) throws -> Response {
        do {
            return try value.decode(responseType)
        } catch let error as DecodingError {
            throw failure(method: method, error: error)
        }
    }

    static func failure(method: String, error: DecodingError) -> GatewayFailure {
        let diagnosis: (category: String, summary: String, path: [CodingKey])
        switch error {
        case .keyNotFound(let key, let context):
            diagnosis = ("missing_required_data", "is missing required data", context.codingPath + [key])
        case .valueNotFound(_, let context):
            diagnosis = ("missing_value", "contains a missing value", context.codingPath)
        case .typeMismatch(_, let context):
            diagnosis = ("type_mismatch", "contains data of the wrong type", context.codingPath)
        case .dataCorrupted(let context):
            diagnosis = ("invalid_data", "contains invalid data", context.codingPath)
        @unknown default:
            diagnosis = ("invalid_data", "contains invalid data", [])
        }
        let admittedMethod = String(method.prefix(maximumMethodCharacters))
        let path = admittedPath(diagnosis.path)
        let message = "The Gateway response for \(admittedMethod) \(diagnosis.summary) at \(path). Try again; if it continues, tap View Logs for details and update Tron on iPhone and the Gateway together."
        return GatewayFailure(
            code: "invalid_response",
            message: message,
            retryable: false,
            details: .object([
                "method": .string(admittedMethod),
                "category": .string(diagnosis.category),
                "codingPath": .string(path),
            ])
        )
    }

    private static func admittedPath(_ codingPath: [CodingKey]) -> String {
        let components = codingPath.prefix(maximumPathComponents).map { key -> String in
            if let index = key.intValue { return "[\(index)]" }
            // Synthesized model CodingKeys are source-owned schema names.
            // Dictionary keys are response-owned data and may contain session
            // IDs, provider values, or secrets, so never retain them in Logs.
            guard String(reflecting: type(of: key)).hasSuffix(".CodingKeys") else {
                return "<redacted>"
            }
            let admitted = key.stringValue.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                    ? Character(String(scalar)) : "?"
            }
            return String(admitted.prefix(64))
        }
        let joined = components.reduce(into: "") { result, component in
            if component.hasPrefix("[") { result += component }
            else { result += result.isEmpty ? component : ".\(component)" }
        }
        return String((joined.isEmpty ? "response" : joined).prefix(maximumPathCharacters))
    }
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
        var eventsActivated = false
        var pending: [String: PendingRequest] = [:]
        var lastInboundAt: ContinuousClock.Instant?
        var overflowResyncSignaled = false
        var info: GatewayInfo?
    }

    nonisolated let events: GatewayEventStream
    private let eventHub: GatewayEventHub
    private let socketFactory: GatewaySocketFactory
    private let clock: MonotonicClock
    private let uuidSource: UUIDSource
    private let frameDecoder: GatewayFrameDecoder
    private let boundedHTTPDataTransport: BoundedHTTPDataTransport
    private let boundedHTTPUploadTransport: BoundedHTTPUploadTransport
    private let boundedHTTPFileTransport: BoundedHTTPFileTransport
    private let performanceSignposts: any PerformanceSignposting
    private var connection: ConnectionEpoch?
    private var generation = 0
    private var profile: GatewayProfile?
    private var token: String?

    var info: GatewayInfo? { connection?.info }

    func activeConnectionID() -> Int? { connection?.id }

    init(
        socketFactory: GatewaySocketFactory = .urlSession,
        clock: MonotonicClock = .continuous,
        uuidSource: UUIDSource = .random,
        frameDecoder: GatewayFrameDecoder = .gateway,
        boundedHTTPDataTransport: BoundedHTTPDataTransport = .urlSession,
        boundedHTTPUploadTransport: BoundedHTTPUploadTransport = .urlSession,
        boundedHTTPFileTransport: BoundedHTTPFileTransport = .urlSession,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        eventBufferPolicy: GatewayEventBufferPolicy = .default
    ) {
        self.socketFactory = socketFactory
        self.clock = clock
        self.uuidSource = uuidSource
        self.frameDecoder = frameDecoder
        self.boundedHTTPDataTransport = boundedHTTPDataTransport
        self.boundedHTTPUploadTransport = boundedHTTPUploadTransport
        self.boundedHTTPFileTransport = boundedHTTPFileTransport
        self.performanceSignposts = performanceSignposts
        let eventHub = GatewayEventHub(policy: eventBufferPolicy)
        self.eventHub = eventHub
        events = GatewayEventStream(hub: eventHub)
    }

    deinit {
        let eventHub = self.eventHub
        Task { await eventHub.finish() }
        connection?.receiveTask?.cancel()
        connection?.livenessTask?.cancel()
        if let socket = connection?.socket {
            Task { await socket.close() }
        }
    }

    func connect(profile: GatewayProfile, token: String) async throws -> GatewayInfo {
        try await establish(profile: profile, token: token, activateEvents: true, isReconnect: false).info
    }

    func connectForLifecycle(profile: GatewayProfile, token: String) async throws -> GatewayConnectionIdentity {
        try await establish(profile: profile, token: token, activateEvents: false, isReconnect: false)
    }

    private func establish(
        profile: GatewayProfile,
        token: String,
        activateEvents: Bool,
        isReconnect: Bool = false
    ) async throws -> GatewayConnectionIdentity {
        let interval = performanceSignposts.begin(.gatewayConnect)
        do {
            let identity = try await establishConnection(
                profile: profile,
                token: token,
                activateEvents: activateEvents,
                isReconnect: isReconnect
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
        activateEvents: Bool,
        isReconnect: Bool
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
        let handshakeTimeout: Duration = isReconnect ? .seconds(5) : .seconds(15)
        // The actor-owned 5/15-second watchdog bounds the handshake. Keep the
        // URL loading inactivity timeout above the 10+8-second application
        // liveness decision so CFNetwork cannot pre-empt it after upgrade.
        var request = URLRequest(url: socketURL, timeoutInterval: GatewaySocketPolicy.requestTimeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = socketFactory.makeConnection(request)
        connection = ConnectionEpoch(id: epochID, socket: socket)

        do {
            let hello: JSONValue = .object([
                "type": .string("hello"),
                "protocolVersion": .number(Double(TronGatewayProtocolContract.protocolVersion)),
                "clientId": .string(uuidSource.next().uuidString),
                "clientRole": .string("mobile"),
            ])
            try await socket.send(JSONEncoder.gateway.encode(hello))
            try requireEpoch(epochID)
            let data = try await withTimeout(duration: handshakeTimeout) { try await socket.receive() }
            try requireEpoch(epochID)
            try GatewayFramePolicy.validateInboundBytes(data)
            let decoded = try JSONDecoder.gateway.decode(GatewayHello.self, from: data)
            try requireEpoch(epochID)
            guard decoded.type == "hello",
                  decoded.protocolVersion == TronGatewayProtocolContract.protocolVersion,
                  decoded.minProtocolVersion == TronGatewayProtocolContract.minimumProtocolVersion else {
                throw GatewayFailure(code: "protocol_mismatch", message: "The Mac gateway protocol is not compatible with this app.", retryable: false, details: nil)
            }
            let admittedChannel = try GatewayChannelPolicy.admit(decoded.gatewayChannel)
            guard admittedChannel == profile.gatewayChannel else {
                throw GatewayFailure(
                    code: "identity_mismatch",
                    message: "The connected Gateway channel does not match this paired server.",
                    retryable: false,
                    details: nil
                )
            }
            guard var epoch = connection, epoch.id == epochID else { throw CancellationError() }
            epoch.info = decoded.info
            epoch.lastInboundAt = clock.now()
            connection = epoch
            if activateEvents { try activateEventDelivery(connectionID: epochID) }
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
        return try await establish(profile: profile, token: token, activateEvents: activateEvents, isReconnect: true)
    }

    func activateEvents(connectionID: Int) throws {
        try activateEventDelivery(connectionID: connectionID)
    }

    private func activateEventDelivery(connectionID: Int) throws {
        try requireEpoch(connectionID)
        guard var epoch = connection, epoch.id == connectionID,
              !epoch.eventsActivated else { return }
        epoch.eventsActivated = true
        connection = epoch
        startReceive(epochID: connectionID)
        startLivenessWait(epochID: connectionID)
    }

    /// Retires only the transport epoch while preserving the selected profile
    /// credentials for the next foreground reconnect. Background suspension is
    /// an intentional transport boundary, not a live subscription interval.
    func retireForBackground() async {
        generation &+= 1
        let retiredConnectionID = connection?.id
        await detachConnection(
            reason: GatewayFailure(code: "backgrounded", message: "Connection retired while the app was backgrounded.", retryable: true, details: nil)
        )
        if let retiredConnectionID { await eventHub.reset(connectionID: retiredConnectionID) }
    }

    func closeIfCurrent(connectionID: Int) async {
        guard connection?.id == connectionID else { return }
        generation &+= 1
        await detachConnection(
            epochID: connectionID,
            reason: GatewayFailure(code: "retired", message: "Connection ownership was retired.", retryable: true, details: nil)
        )
        await eventHub.reset(connectionID: connectionID)
    }

    func close() async {
        generation &+= 1
        profile = nil
        token = nil
        let retiredConnectionID = connection?.id
        await detachConnection(
            reason: GatewayFailure(code: "closed", message: "Connection closed", retryable: true, details: nil)
        )
        if let retiredConnectionID { await eventHub.reset(connectionID: retiredConnectionID) }
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
        return try GatewayResponseDecoding.decode(value, as: responseType, method: method)
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
        return try GatewayResponseDecoding.decode(value, as: responseType, method: method)
    }

    private func requestValue<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration,
        expectedEpochID: Int?
    ) async throws -> JSONValue {
        guard let epoch = connection,
              expectedEpochID == nil || expectedEpochID == epoch.id else {
            throw Self.definitelyNotSentFailure()
        }
        let epochID = epoch.id
        let socket = epoch.socket
        let id = uuidSource.next().uuidString
        let frame = GatewayRequest(id: id, method: method, params: try JSONValue.encode(params))
        let data = try JSONEncoder.gateway.encode(frame)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var current = connection, current.id == epochID else {
                    continuation.resume(throwing: Self.definitelyNotSentFailure(
                        code: "replaced",
                        message: "Connection replaced"
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
        try requireUploadSize(data.count)
        let context = try uploadContext(name: name, mimeType: mimeType)
        var request = context.request
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        let (responseData, http) = try await boundedHTTPDataTransport.data(
            for: request,
            maximumBytes: GatewayUploadPolicy.maximumResponseBytes
        )
        // The upload is an independently staged HTTP resource. A WebSocket
        // reconnect while the bytes are in flight must not discard a
        // successful photo upload or turn it into a misleading failure.
        return try admitUploadResponse(responseData, http: http, context: context)
    }

    func discardUpload(_ id: String) async throws {
        guard UUID(uuidString: id) != nil else {
            throw GatewayFailure(
                code: "invalid_request",
                message: "Attachment staging identity is invalid.",
                retryable: false,
                details: nil
            )
        }
        guard let profile, let token else {
            throw GatewayFailure(
                code: "not_paired",
                message: "No paired gateway is selected.",
                retryable: false,
                details: nil
            )
        }
        guard let url = profile.httpURL(path: "/v1/uploads/\(id)") else {
            throw Self.invalidProfileEndpoint()
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await boundedHTTPDataTransport.data(
            for: request,
            maximumBytes: GatewayUploadPolicy.maximumResponseBytes
        )
        guard self.profile?.id == profile.id else { throw CancellationError() }
        guard http.statusCode != 204, http.statusCode != 404 else { return }
        struct FailureEnvelope: Decodable { let error: GatewayFailure }
        if let failure = try? JSONDecoder.gateway.decode(FailureEnvelope.self, from: data).error {
            throw failure
        }
        throw GatewayFailure(
            code: "upload_failed",
            message: "Attachment staging could not be discarded (HTTP \(http.statusCode)).",
            retryable: http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500,
            details: nil
        )
    }

    func upload(
        name: String,
        mimeType: String,
        fileURL: URL,
        byteCount: Int
    ) async throws -> String {
        try requireUploadSize(byteCount)
        let context = try uploadContext(name: name, mimeType: mimeType)
        var request = context.request
        request.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
        let (responseData, http) = try await boundedHTTPUploadTransport.data(
            for: request,
            fileURL: fileURL,
            maximumBytes: GatewayUploadPolicy.maximumResponseBytes
        )
        return try admitUploadResponse(responseData, http: http, context: context)
    }

    private struct UploadContext {
        let profileID: String
        let request: URLRequest
    }

    private func uploadContext(name: String, mimeType: String) throws -> UploadContext {
        // Upload staging is an authenticated HTTP operation owned by the paired
        // profile, not by a disposable WebSocket epoch. A brief socket
        // reconnect must not prevent selecting or staging an attachment.
        guard let profile, let token else {
            throw GatewayFailure(code: "not_paired", message: "No paired gateway is selected.", retryable: false, details: nil)
        }
        guard let url = profile.httpURL(
            path: "/v1/uploads",
            queryItems: [URLQueryItem(name: "name", value: name)]
        ) else { throw Self.invalidProfileEndpoint() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        return UploadContext(profileID: profile.id, request: request)
    }

    private func requireUploadSize(_ byteCount: Int) throws {
        guard byteCount > 0, byteCount <= GatewayUploadPolicy.maximumRequestBytes else {
            throw GatewayFailure(
                code: "upload_failed",
                message: "Attachments may contain 1 byte through 25 MiB.",
                retryable: false,
                details: nil
            )
        }
    }

    private func admitUploadResponse(
        _ data: Data,
        http: HTTPURLResponse,
        context: UploadContext
    ) throws -> String {
        guard profile?.id == context.profileID else { throw CancellationError() }
        guard http.statusCode == 201 else {
            struct FailureEnvelope: Decodable { let error: GatewayFailure }
            if let failure = try? JSONDecoder.gateway.decode(FailureEnvelope.self, from: data).error {
                throw failure
            }
            let retryable = http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500
            throw GatewayFailure(
                code: "upload_failed",
                message: "Attachment upload failed (HTTP \(http.statusCode)).",
                retryable: retryable,
                details: nil
            )
        }
        struct Envelope: Decodable { struct Upload: Decodable { let id: String }; let upload: Upload }
        do {
            let id = try JSONDecoder.gateway.decode(Envelope.self, from: data).upload.id
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Upload response did not contain an ID")) }
            return id
        } catch {
            throw GatewayFailure(code: "upload_failed", message: "The Gateway returned an invalid attachment response.", retryable: true, details: nil)
        }
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
        sessionID: String? = nil,
        profileID: String,
        maximumBytes: Int
    ) async throws -> (Data, String) {
        // Transcript blobs remain profile-owned across disposable WebSocket
        // epochs. This keeps thumbnails and an open preview stable while the
        // event channel reconnects and rebaselines.
        guard let profile, profile.id == profileID, let token else {
            throw CancellationError()
        }
        let value = try await boundedBlob(
            id: id,
            sessionID: sessionID,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        guard self.profile?.id == profileID else { throw CancellationError() }
        return value
    }

    func displayArtifactFile(
        id: String,
        sessionID: String,
        profileID: String,
        maximumBytes: Int,
        expectedBytes: Int64
    ) async throws -> URL {
        guard let profile, profile.id == profileID, let token else { throw CancellationError() }
        let downloaded = try await boundedBlobFile(
            id: id,
            sessionID: sessionID,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        do {
            guard downloaded.byteCount == expectedBytes else {
                throw GatewayFailure(
                    code: "blob_failed",
                    message: "The display media changed while it was downloading.",
                    retryable: true,
                    details: nil
                )
            }
            try Task.checkCancellation()
            guard self.profile?.id == profileID else { throw CancellationError() }
            return downloaded.url
        } catch {
            BoundedHTTPFileStaging.shared.discard(downloaded.url)
            throw error
        }
    }

    func blobFile(id: String, maximumBytes: Int, expectedBytes: Int64? = nil) async throws -> URL {
        guard let profile, let token, let connectionID = connection?.id else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        let downloaded = try await boundedBlobFile(
            id: id,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        do {
            if let expectedBytes, downloaded.byteCount != expectedBytes {
                throw GatewayFailure(
                    code: "blob_failed",
                    message: "The export size changed while it was downloading. Try exporting again.",
                    retryable: true,
                    details: nil
                )
            }
            try requireEpoch(connectionID)
            guard self.profile?.id == profile.id else { throw CancellationError() }
            return downloaded.url
        } catch {
            BoundedHTTPFileStaging.shared.discard(downloaded.url)
            throw error
        }
    }

    private func boundedBlob(
        id: String,
        sessionID: String? = nil,
        profile: GatewayProfile,
        token: String,
        maximumBytes: Int
    ) async throws -> (Data, String) {
        guard let url = mediaURL(id: id, sessionID: sessionID, profile: profile) else {
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

    private func boundedBlobFile(
        id: String,
        sessionID: String? = nil,
        profile: GatewayProfile,
        token: String,
        maximumBytes: Int
    ) async throws -> BoundedHTTPDownloadedFile {
        guard let url = mediaURL(id: id, sessionID: sessionID, profile: profile) else {
            throw Self.invalidProfileEndpoint()
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let downloaded = try await boundedHTTPFileTransport.download(
            for: request,
            maximumBytes: maximumBytes
        )
        guard downloaded.response.statusCode == 200 || downloaded.response.statusCode == 206 else {
            BoundedHTTPFileStaging.shared.discard(downloaded.url)
            throw GatewayFailure(code: "blob_failed", message: "The export is no longer available. Try exporting again.", retryable: true, details: nil)
        }
        return downloaded
    }

    private func mediaURL(id: String, sessionID: String? = nil, profile: GatewayProfile) -> URL? {
        Self.mediaPath(id: id, sessionID: sessionID).flatMap { profile.httpURL(path: $0) }
    }

    nonisolated static func mediaPath(id: String, sessionID: String? = nil) -> String? {
        if let sessionID {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard UUID(uuidString: id) != nil,
                  !sessionID.isEmpty, sessionID.utf8.count <= 200,
                  let encodedSession = sessionID.addingPercentEncoding(withAllowedCharacters: allowed),
                  !encodedSession.isEmpty else { return nil }
            return "/v1/sessions/\(encodedSession)/display-artifacts/\(id)"
        }
        if id.hasPrefix("upload:") {
            let uploadID = String(id.dropFirst("upload:".count))
            guard UUID(uuidString: uploadID) != nil else { return nil }
            return "/v1/uploads/\(uploadID)"
        }
        return "/v1/blobs/\(id)"
    }

    private func startReceive(epochID: Int) {
        guard var epoch = connection, epoch.id == epochID,
              epoch.receiveTask == nil else { return }
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
        guard var completedEpoch = connection, completedEpoch.id == epochID else { return }
        completedEpoch.receiveTask = nil
        connection = completedEpoch
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
        guard var epoch = connection, epoch.id == epochID,
              epoch.livenessTask == nil else { return }
        let clock = self.clock
        let socket = epoch.socket
        epoch.livenessTask = Task { [weak self, clock, socket] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(GatewayLivenessPolicy.probeInterval)
                    try Task.checkCancellation()
                    try await socket.ping()
                } catch is CancellationError {
                    return
                } catch {
                    await self?.livenessFailed(error, epochID: epochID)
                    return
                }
            }
        }
        connection = epoch
    }

    private func livenessFailed(_ error: Error, epochID: Int) async {
        guard ownsEpoch(epochID) else { return }
        await disconnectEpoch(epochID: epochID, failure: Self.transportFailure(error))
    }

    private func disconnectEpoch(epochID: Int, failure: GatewayFailure) async {
        guard await detachConnection(epochID: epochID, reason: failure) else { return }
        await eventHub.reset(connectionID: epochID)
        _ = await eventHub.yield(GatewayEventDelivery(
            connectionID: epochID,
            event: GatewayEvent(
                type: "event",
                topic: "transport.disconnected",
                sessionId: nil,
                payload: .object(["message": .string(failure.message)]),
                admittedBytes: 256
            )
        ), bytes: 256)
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
            let admittedEvent = GatewayEvent(
                type: event.type,
                topic: event.topic,
                sessionId: event.sessionId,
                payload: event.payload,
                admittedBytes: data.count
            )
            if await eventHub.yield(GatewayEventDelivery(
                connectionID: epochID,
                event: admittedEvent
            ), bytes: data.count) {
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
                : Self.definitelyNotSentFailure(cause: reason))
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

    private nonisolated static func definitelyNotSentFailure(
        code: String = "disconnected",
        message: String = "The Mac gateway is offline.",
        cause: Error? = nil
    ) -> GatewayDefinitelyNotSentError {
        GatewayDefinitelyNotSentError(failure: GatewayFailure(
            code: code,
            message: message,
            retryable: true,
            details: cause.map { .object(["cause": .string(transportFailure($0).code)]) }
        ))
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
        if let definitelyNotSent = error as? GatewayDefinitelyNotSentError { return definitelyNotSent.failure }
        if let possiblySent = error as? GatewayPossiblySentError { return possiblySent.failure }
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
