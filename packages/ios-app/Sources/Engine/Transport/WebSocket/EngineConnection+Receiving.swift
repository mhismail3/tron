import Foundation

@MainActor
extension EngineConnection {
    // MARK: - Receive Loop

    func handleSendTransportFailure(
        _ error: Error,
        operation: String,
        failedTask: URLSessionWebSocketTask
    ) async {
        guard isConnectedFlag, engineConnectionTask === failedTask else { return }
        logger.warning("Send failure indicates connection loss for \(operation): \(error.localizedDescription)", category: .websocket)
        await handleDisconnect()
    }

    func receiveLoop() async {
        logger.verbose("Receive loop running...", category: .websocket)
        var messageCount = 0

        while isConnectedFlag {
            do {
                guard let message = try await engineConnectionTask?.receive() else {
                    logger.warning("Receive returned nil, exiting loop", category: .websocket)
                    break
                }

                messageCount += 1
                let data: Data
                switch message {
                case .data(let d):
                    data = d
                    logger.verbose("Received binary message #\(messageCount): \(d.count) bytes", category: .websocket)
                case .string(let text):
                    guard let d = text.data(using: .utf8) else {
                        logger.warning("Failed to convert string message to data", category: .websocket)
                        continue
                    }
                    data = d
                    logger.verbose(
                        "Received string message #\(messageCount): \(d.count) bytes",
                        category: .websocket
                    )
                @unknown default:
                    logger.warning("Received unknown message type", category: .websocket)
                    continue
                }

                let parsed = await Task.detached(priority: .userInitiated) {
                    Self.parseInboundMessage(data)
                }.value
                handleParsedMessage(parsed, rawData: data)

            } catch {
                if isConnectedFlag {
                    logger.error("Receive loop error: \(error.localizedDescription)", category: .websocket)
                    await handleDisconnect()
                } else {
                    logger.debug("Receive loop ended (disconnected)", category: .websocket)
                }
                break
            }
        }
        logger.verbose("Receive loop exited after \(messageCount) messages", category: .websocket)
    }

    enum ParsedInboundMessage: Sendable {
        case event(EngineEventDelivery)
        case response(id: String)
        case invalid(reason: InvalidInboundMessageReason)
    }

    enum InvalidInboundMessageReason: Sendable {
        case malformedJSON
        case malformedEvent
        case missingRouting
    }

    private struct InboundRoutingFrame: Decodable, Sendable {
        let type: String?
        let id: String?
        let topic: String?
        let subscriptionId: String?
        let cursor: UInt64?
        let event: ServerEventPayload?
    }

    /// Decode potentially large response/event frames away from the main
    /// actor. The receive loop still awaits each parse in order, so event
    /// ordering and request correlation remain deterministic.
    nonisolated static func parseInboundMessage(_ data: Data) -> ParsedInboundMessage {
        guard let frame = try? JSONDecoder().decode(InboundRoutingFrame.self, from: data) else {
            return .invalid(reason: .malformedJSON)
        }

        if frame.type == "event" {
            guard let event = frame.event,
                  let eventData = try? JSONEncoder().encode(event) else {
                return .invalid(reason: .malformedEvent)
            }
            return .event(
                EngineEventDelivery(
                    topic: frame.topic,
                    subscriptionId: frame.subscriptionId,
                    cursor: frame.cursor.map(EngineStreamCursor.init(rawValue:)),
                    event: event,
                    eventData: eventData
                )
            )
        }

        if let id = frame.id {
            return .response(id: id)
        }
        return .invalid(reason: .missingRouting)
    }

    func handleMessage(_ data: Data) async {
        let parsed = await Task.detached(priority: .userInitiated) {
            Self.parseInboundMessage(data)
        }.value
        handleParsedMessage(parsed, rawData: data)
    }

    private func handleParsedMessage(_ parsed: ParsedInboundMessage, rawData data: Data) {
        switch parsed {
        case .invalid(.malformedJSON):
            logger.warning(
                "Received malformed non-JSON message (\(data.count) bytes)",
                category: .websocket
            )
        case .invalid(.malformedEvent):
            logger.warning("Received malformed engine event frame", category: .websocket)
        case .invalid(.missingRouting):
            logger.warning("Received message without id or type", category: .websocket)
        case .event(let delivery):
            #if DEBUG || BETA
            logger.logEvent(
                type: delivery.event.type,
                sessionId: delivery.event.sessionId,
                data: delivery.event.data.map {
                    String(describing: $0.value).prefix(300).description
                }
            )
            #endif
            onEvent?(delivery)
        case .response(let id):
            timeoutTasks[id]?.cancel()
            timeoutTasks.removeValue(forKey: id)

            if let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: data)
                #if DEBUG || BETA
                logger.debug("Resolved engine response for id=\(id), remaining pending: \(pendingRequests.count)", category: .websocket)
                #endif
            } else {
                logger.warning("Received response for unknown/expired id=\(id)", category: .websocket)
            }
        }
    }

    // MARK: - Heartbeat

    func heartbeatLoop() async {
        logger.verbose("Heartbeat loop running (interval: \(String(format: "%.0f", Self.heartbeatInterval))s)...", category: .websocket)
        var pingCount = 0

        while isConnectedFlag {
            try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
            guard isConnectedFlag else { break }

            if isInBackground {
                logger.verbose("Skipping ping - app in background", category: .websocket)
                continue
            }

            pingCount += 1
            do {
                guard let task = engineConnectionTask else {
                    throw EngineConnectionError.notConnected
                }
                let pingStart = CFAbsoluteTimeGetCurrent()
                try await sendPing(on: task, timeout: Self.connectionVerificationTimeout)
                let pingDuration = (CFAbsoluteTimeGetCurrent() - pingStart) * 1000
                logger.verbose("Ping #\(pingCount) successful (\(String(format: "%.1f", pingDuration))ms)", category: .websocket)

                if reconnectAttempts > 0 {
                    logger.info("Connection verified via ping - resetting reconnect counter", category: .websocket)
                    reconnectAttempts = 0
                }
            } catch {
                logger.warning("Ping #\(pingCount) failed: \(error.localizedDescription)", category: .websocket)
                await handleDisconnect()
                break
            }
        }
        logger.verbose("Heartbeat loop exited after \(pingCount) pings", category: .websocket)
    }

    // MARK: - Pending Request Cleanup

    func failPendingRequest(id: String, error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Fail all pending engine requests and cancel their timeout tasks.
    func failPendingRequests(error: Error) {
        let pendingCount = pendingRequests.count
        for (id, continuation) in pendingRequests {
            logger.debug("Failing pending request id=\(id)", category: .websocket)
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()

        let timeoutCount = timeoutTasks.count
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        logger.debug("Cleared \(pendingCount) pending requests and \(timeoutCount) timeout tasks", category: .websocket)
    }

}
