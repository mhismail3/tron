import Foundation

enum EngineInboundWireKind: String, Sendable {
    case binary
    case text
}

struct EngineDecodedInboundFrame: Sendable {
    let data: Data
    let message: EngineConnection.ParsedInboundMessage
    let wireKind: EngineInboundWireKind
}

/// One serial executor owns raw frame normalization and routing decode for the
/// life of a connection. Awaiting it preserves wire order while keeping UTF-8
/// conversion and JSON scanning off the main actor without allocating one
/// detached task per frame.
actor EngineInboundFrameDecoder {
    func decode(data: Data) -> EngineDecodedInboundFrame {
        EngineDecodedInboundFrame(
            data: data,
            message: EngineConnection.parseInboundMessage(data),
            wireKind: .binary
        )
    }

    func decode(text: String) -> EngineDecodedInboundFrame {
        let data = Data(text.utf8)
        return EngineDecodedInboundFrame(
            data: data,
            message: EngineConnection.parseInboundMessage(data),
            wireKind: .text
        )
    }
}

@MainActor
extension EngineConnection {
    // MARK: - Receive Loop

    func handleSendTransportFailure(
        _ error: Error,
        operation: String,
        failedTask: URLSessionWebSocketTask
    ) async {
        guard isConnectedFlag, engineConnectionTask === failedTask else { return }
        let generation = transportGeneration
        logger.warning("Send failure indicates connection loss for \(operation): \(error.localizedDescription)", category: .websocket)
        await handleDisconnect(
            expectedTask: failedTask,
            expectedGeneration: generation
        )
    }

    func receiveLoop(
        on task: URLSessionWebSocketTask,
        generation: UInt64
    ) async {
        logger.verbose("Receive loop running...", category: .websocket)
        var messageCount = 0

        while ownsTransport(task, generation: generation), !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard ownsTransport(task, generation: generation),
                      !Task.isCancelled else {
                    logger.debug("Receive loop retired before message delivery", category: .websocket)
                    break
                }

                let frame: EngineDecodedInboundFrame
                switch message {
                case .data(let d):
                    frame = await inboundFrameDecoder.decode(data: d)
                case .string(let text):
                    frame = await inboundFrameDecoder.decode(text: text)
                @unknown default:
                    logger.warning("Received unknown message type", category: .websocket)
                    continue
                }

                guard ownsTransport(task, generation: generation),
                      !Task.isCancelled else {
                    logger.debug("Receive loop retired during frame decoding", category: .websocket)
                    break
                }
                messageCount += 1
                logger.verbose(
                    "Received \(frame.wireKind.rawValue) frame #\(messageCount): \(frame.data.count) bytes",
                    category: .websocket
                )
                handleParsedMessage(frame.message, rawData: frame.data)

            } catch {
                if ownsTransport(task, generation: generation),
                   !Task.isCancelled {
                    logger.error("Receive loop error: \(error.localizedDescription)", category: .websocket)
                    await handleDisconnect(
                        expectedTask: task,
                        expectedGeneration: generation
                    )
                } else {
                    logger.debug("Receive loop ended (retired transport)", category: .websocket)
                }
                break
            }
        }
        logger.verbose("Receive loop exited after \(messageCount) messages", category: .websocket)
    }

    enum ParsedInboundMessage: Sendable {
        case event(EngineEventDelivery)
        case response(id: String)
        case terminal(TerminalInboundFrame)
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

        if frame.type?.hasPrefix("terminal.") == true,
           frame.id == nil,
           let terminal = try? JSONDecoder().decode(TerminalInboundFrame.self, from: data) {
            return .terminal(terminal)
        }

        if let id = frame.id {
            return .response(id: id)
        }
        return .invalid(reason: .missingRouting)
    }

    func handleMessage(_ data: Data) async {
        let frame = await inboundFrameDecoder.decode(data: data)
        handleParsedMessage(frame.message, rawData: frame.data)
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
                payloadBytes: delivery.eventData.count
            )
            #endif
            onEvent?(delivery)
        case .terminal(let frame):
            onTerminalFrame?(frame)
        case .response(let id):
            if finishPendingRequest(id: id, result: .success(data)) {
                #if DEBUG || BETA
                logger.debug("Resolved engine response for id=\(id), remaining pending: \(pendingRequests.count)", category: .websocket)
                #endif
            } else {
                // Late responses are expected after a caller cancellation or
                // request-local timeout. They do not imply protocol damage.
                logger.debug(
                    "Ignored response for retired or unknown request id=\(id)",
                    category: .websocket
                )
            }
        }
    }

    // MARK: - Heartbeat

    func heartbeatLoop(
        on task: URLSessionWebSocketTask,
        generation: UInt64
    ) async {
        logger.verbose("Heartbeat loop running (interval: \(String(format: "%.0f", Self.heartbeatInterval))s)...", category: .websocket)
        var pingCount = 0

        while ownsTransport(task, generation: generation), !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Self.heartbeatInterval))
            } catch {
                break
            }
            guard ownsTransport(task, generation: generation),
                  !Task.isCancelled else { break }

            if isInBackground {
                logger.verbose("Skipping ping - app in background", category: .websocket)
                continue
            }

            pingCount += 1
            do {
                let pingStart = CFAbsoluteTimeGetCurrent()
                try await sendPing(on: task, timeout: Self.connectionVerificationTimeout)
                guard ownsTransport(task, generation: generation),
                      !Task.isCancelled else {
                    break
                }
                let pingDuration = (CFAbsoluteTimeGetCurrent() - pingStart) * 1000
                logger.verbose("Ping #\(pingCount) successful (\(String(format: "%.1f", pingDuration))ms)", category: .websocket)

                if reconnectAttempts > 0 {
                    logger.info("Connection verified via ping - resetting reconnect counter", category: .websocket)
                    reconnectAttempts = 0
                }
            } catch {
                guard ownsTransport(task, generation: generation),
                      !Task.isCancelled else {
                    logger.debug("Ignoring ping failure from retired transport", category: .websocket)
                    break
                }
                logger.warning("Ping #\(pingCount) failed: \(error.localizedDescription)", category: .websocket)
                await handleDisconnect(
                    expectedTask: task,
                    expectedGeneration: generation
                )
                break
            }
        }
        logger.verbose("Heartbeat loop exited after \(pingCount) pings", category: .websocket)
    }

    // MARK: - Pending Request Cleanup

    func failPendingRequest(id: String, error: Error) {
        finishPendingRequest(id: id, result: .failure(error))
    }

    /// Fail all pending engine requests and cancel their timeout tasks.
    func failPendingRequests(error: Error) {
        let pendingCount = pendingRequests.count
        let requests = pendingRequests
        pendingRequests.removeAll(keepingCapacity: true)
        for (id, pending) in requests {
            logger.debug("Failing pending request id=\(id)", category: .websocket)
            pending.finish(.failure(error))
        }
        logger.debug(
            "Cleared \(pendingCount) pending requests and owned deadlines",
            category: .websocket
        )
    }

}
