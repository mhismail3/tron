import Foundation

@MainActor
extension EngineConnection {
    // MARK: - Engine Protocol Request/Response

    @discardableResult
    func hello(
        sessionId: String? = nil,
        workspaceId: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> EngineHelloResult {
        let message = EngineHelloFrame(
            id: UUID().uuidString,
            protocolVersion: 1,
            clientName: "tron-ios",
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        return try await sendProtocolMessage(message, id: message.id, operation: "hello", timeout: timeout)
    }

    func invokeRead<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        options: EngineInvocationOptions = EngineInvocationOptions()
    ) async throws -> R {
        try await invoke(functionId: functionId, payload: payload, idempotencyKey: nil, options: options)
    }

    func invokeWrite<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey,
        options: EngineInvocationOptions = EngineInvocationOptions()
    ) async throws -> R {
        try await invoke(functionId: functionId, payload: payload, idempotencyKey: idempotencyKey, options: options)
    }

    func subscribe(
        topic: String,
        cursor: EngineStreamCursor? = nil,
        filters: [String: AnyCodable]? = nil,
        limit: Int? = nil,
        context: EngineInvocationContext? = nil
    ) async throws -> EngineSubscription {
        let message = EngineSubscribeFrame(
            id: UUID().uuidString,
            topic: topic,
            cursor: cursor?.rawValue,
            filters: filters,
            limit: limit,
            context: context
        )
        return try await sendResponseMessage(message, id: message.id, operation: "subscribe", timeout: nil)
    }

    func poll(
        subscriptionId: String? = nil,
        topic: String? = nil,
        cursor: EngineStreamCursor? = nil,
        filters: [String: AnyCodable]? = nil,
        limit: Int? = nil,
        context: EngineInvocationContext? = nil
    ) async throws -> EngineStreamPage {
        let message = EnginePollFrame(
            id: UUID().uuidString,
            subscriptionId: subscriptionId,
            topic: topic,
            cursor: cursor?.rawValue,
            filters: filters,
            limit: limit,
            context: context
        )
        return try await sendResponseMessage(message, id: message.id, operation: "poll", timeout: nil)
    }

    func ack(subscriptionId: String, cursor: EngineStreamCursor) async throws {
        let message = EngineAckFrame(id: UUID().uuidString, subscriptionId: subscriptionId, cursor: cursor.rawValue)
        let _: EmptyParams = try await sendResponseMessage(message, id: message.id, operation: "ack", timeout: nil)
    }

    @discardableResult
    func unsubscribe(subscriptionId: String) async throws -> Bool {
        let message = EngineUnsubscribeFrame(
            id: UUID().uuidString,
            subscriptionId: subscriptionId
        )
        let result: EngineUnsubscribeResult = try await sendResponseMessage(
            message,
            id: message.id,
            operation: "unsubscribe",
            timeout: nil
        )
        return result.unsubscribed
    }

    func invoke<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey?,
        options: EngineInvocationOptions
    ) async throws -> R {
        let requestId = UUID().uuidString
        let message = EngineFunctionCallFrame(
            id: requestId,
            functionId: functionId.rawValue,
            payload: payload,
            idempotencyKey: idempotencyKey?.rawValue,
            context: options.context
        )
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.logEngineRequest(functionId: functionId.rawValue, payload: payload, id: requestId)
        do {
            let value: R = try await sendResponseMessage(
                message,
                id: requestId,
                operation: functionId.rawValue,
                timeout: options.timeout
            )
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            logger.logEngineResponse(functionId: functionId.rawValue, id: requestId, success: true, duration: duration, result: value)
            return value
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let detail = (error as? EngineProtocolError)?.diagnosticSummary ?? error.localizedDescription
            logger.logEngineResponse(
                functionId: functionId.rawValue,
                id: requestId,
                success: false,
                duration: duration,
                error: detail
            )
            throw error
        }
    }

    func sendProtocolMessage<M: Encodable, R: Decodable>(
        _ message: M,
        id: String,
        operation: String,
        timeout: TimeInterval?
    ) async throws -> R {
        let data = try await sendMessage(message, id: id, operation: operation, timeout: timeout)
        let responseDecoder = EngineResponseDecoder(R.self)
        do {
            let decoded = try await Task.detached(priority: .userInitiated) {
                do {
                    return try responseDecoder.decode(from: data)
                } catch {
                    throw EngineConnectionError.decodingError(error.localizedDescription)
                }
            }.value
            guard let response = decoded.value as? R else {
                throw EngineConnectionError.invalidResponse
            }
            return response
        } catch let error as EngineConnectionError {
            throw error
        } catch {
            throw EngineConnectionError.decodingError(error.localizedDescription)
        }
    }

    func sendResponseMessage<M: Encodable, R: Decodable>(
        _ message: M,
        id: String,
        operation: String,
        timeout: TimeInterval?
    ) async throws -> R {
        let data = try await sendMessage(message, id: id, operation: operation, timeout: timeout)
        let responseDecoder = EngineResponseDecoder(
            EngineResponseEnvelope<R>.self
        )
        do {
            let decoded = try await Task.detached(priority: .userInitiated) {
                do {
                    return try responseDecoder.decode(from: data)
                } catch {
                    throw EngineConnectionError.decodingError(error.localizedDescription)
                }
            }.value
            guard let response = decoded.value as? EngineResponseEnvelope<R> else {
                throw EngineConnectionError.invalidResponse
            }
            if response.ok, let result = response.result {
                return result
            }
            if let error = response.error {
                throw error
            }
            throw EngineConnectionError.invalidResponse
        } catch let error as EngineProtocolError {
            throw error
        } catch let error as EngineConnectionError {
            throw error
        } catch {
            throw EngineConnectionError.decodingError(error.localizedDescription)
        }
    }

    func sendMessage<M: Encodable>(
        _ message: M,
        id requestId: String,
        operation: String,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let timeoutInterval = timeout ?? requestTimeout

        guard isConnectedFlag, let task = engineConnectionTask else {
            logger.error("Cannot send \(operation): not connected (isConnectedFlag=\(isConnectedFlag), task=\(engineConnectionTask != nil ? "exists" : "nil"))", category: .websocket)
            throw EngineConnectionError.notConnected
        }

        guard let data = try? JSONEncoder().encode(message) else {
            logger.error("Failed to encode engine message for \(operation)", category: .websocket)
            throw EngineConnectionError.encodingError
        }
        try Self.validateOutboundMessageSize(
            actualBytes: data.count,
            maxBytes: negotiatedMaxMessageSize
        )

        #if DEBUG || BETA
        logger.logWebSocketMessage(direction: "→ SEND", type: operation, size: data.count)
        #endif

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[requestId] = continuation
                logger.verbose("Registered pending request id=\(requestId), total pending: \(pendingRequests.count)", category: .websocket)

                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutInterval))
                    await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                        logger.error("Request timeout for \(operation) id=\(requestId) after \(timeoutInterval)s", category: .websocket)
                        pending.resume(throwing: EngineConnectionError.timeout)
                        self?.timeoutTasks.removeValue(forKey: requestId)
                        return
                    }
                    self?.timeoutTasks.removeValue(forKey: requestId)
                    }
                }
                timeoutTasks[requestId] = timeoutTask

                // Register correlation before sending so an immediate server
                // response can never arrive ahead of its continuation.
                let socketMessage = Self.engineTextMessage(from: data)
                task.send(socketMessage) { [self] error in
                    Task { @MainActor [self] in
                        guard let error else {
                            logger.verbose("Message sent successfully for \(operation) id=\(requestId)", category: .websocket)
                            logger.verbose("Waiting for response to \(operation) id=\(requestId)...", category: .websocket)
                            return
                        }

                        logger.error("Failed to send message for \(operation): \(error.localizedDescription)", category: .websocket)
                        if ConnectionErrorClassifier.requiresConnectionRecovery(error) {
                            failPendingRequest(
                                id: requestId,
                                error: EngineConnectionError.connectionFailed(error.localizedDescription)
                            )
                            await handleSendTransportFailure(
                                error,
                                operation: operation,
                                failedTask: task
                            )
                        } else {
                            failPendingRequest(id: requestId, error: error)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: requestId)
            }
        }
    }

    /// Cancellation retires only the requesting task. It must not wait for the
    /// ordinary 30-second deadline or disturb unrelated work on the shared
    /// WebSocket.
    func cancelPendingRequest(id requestId: String) {
        timeoutTasks.removeValue(forKey: requestId)?.cancel()
        pendingRequests.removeValue(forKey: requestId)?.resume(
            throwing: CancellationError()
        )
    }

    nonisolated static func validateOutboundMessageSize(
        actualBytes: Int,
        maxBytes: Int?
    ) throws {
        guard let maxBytes, maxBytes > 0, actualBytes > maxBytes else { return }
        throw EngineConnectionError.messageTooLarge(
            actualBytes: actualBytes,
            maxBytes: maxBytes
        )
    }

    nonisolated static func engineTextMessage(from data: Data) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: data, as: UTF8.self))
    }

}
