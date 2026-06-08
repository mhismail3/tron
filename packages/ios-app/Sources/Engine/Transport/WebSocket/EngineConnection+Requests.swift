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
        let envelope: EngineFunctionCallEnvelope<R> = try await sendResponseMessage(
            message,
            id: requestId,
            operation: functionId.rawValue,
            timeout: options.timeout
        )
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        if let error = envelope.child.error {
            let protocolError = EngineProtocolError(
                code: error.details?["code"]?.stringValue ?? error.kind ?? "ENGINE_ERROR",
                message: error.details?["message"]?.stringValue ?? error.message ?? "Engine invocation failed",
                details: error.details?["details"]?.dictionaryValue?.mapValues { AnyCodable($0) } ?? error.details
            )
            logger.logEngineResponse(functionId: functionId.rawValue, id: requestId, success: false, duration: duration, error: protocolError.diagnosticSummary)
            throw protocolError
        }
        guard let value = envelope.child.value else {
            logger.logEngineResponse(functionId: functionId.rawValue, id: requestId, success: false, duration: duration, error: "Missing child value")
            throw EngineConnectionError.invalidResponse
        }
        logger.logEngineResponse(functionId: functionId.rawValue, id: requestId, success: true, duration: duration, result: value)
        return value
    }

    func sendProtocolMessage<M: Encodable, R: Decodable>(
        _ message: M,
        id: String,
        operation: String,
        timeout: TimeInterval?
    ) async throws -> R {
        let data = try await sendMessage(message, id: id, operation: operation, timeout: timeout)
        do {
            return try JSONDecoder().decode(R.self, from: data)
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
        do {
            let response = try JSONDecoder().decode(EngineResponseEnvelope<R>.self, from: data)
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

        #if DEBUG || BETA
        logger.logWebSocketMessage(direction: "→ SEND", type: operation, size: data.count, preview: String(data: data, encoding: .utf8))
        #endif

        let socketMessage = Self.engineTextMessage(from: data)
        do {
            try await task.send(socketMessage)
            logger.verbose("Message sent successfully for \(operation) id=\(requestId)", category: .websocket)
        } catch {
            logger.error("Failed to send message for \(operation): \(error.localizedDescription)", category: .websocket)
            if ConnectionErrorClassifier.requiresConnectionRecovery(error) {
                await handleSendTransportFailure(error, operation: operation)
                throw EngineConnectionError.connectionFailed(error.localizedDescription)
            }
            throw error
        }

        logger.verbose("Waiting for response to \(operation) id=\(requestId)...", category: .websocket)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[requestId] = continuation
            logger.verbose("Registered pending request id=\(requestId), total pending: \(pendingRequests.count)", category: .websocket)

            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutInterval))
                let shouldRecoverConnection = await MainActor.run {
                    if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                        logger.error("Request timeout for \(operation) id=\(requestId) after \(timeoutInterval)s", category: .websocket)
                        pending.resume(throwing: EngineConnectionError.timeout)
                        self?.timeoutTasks.removeValue(forKey: requestId)
                        return true
                    }
                    self?.timeoutTasks.removeValue(forKey: requestId)
                    return false
                }
                if shouldRecoverConnection {
                    await self?.handleDisconnect()
                }
            }
            timeoutTasks[requestId] = timeoutTask
        }
    }

    nonisolated static func engineTextMessage(from data: Data) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: data, as: UTF8.self))
    }

}
