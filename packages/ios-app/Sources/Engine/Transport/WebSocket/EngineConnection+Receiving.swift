import Foundation

@MainActor
extension EngineConnection {
    // MARK: - Receive Loop

    func handleSendTransportFailure(_ error: Error, operation: String) async {
        guard isConnectedFlag else { return }
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
                    logger.verbose("Received string message #\(messageCount): \(text.prefix(200))", category: .websocket)
                @unknown default:
                    logger.warning("Received unknown message type", category: .websocket)
                    continue
                }

                handleMessage(data)

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

    func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Received non-JSON message: \(String(data: data, encoding: .utf8) ?? "binary")", category: .websocket)
            return
        }

        if let type = json["type"] as? String, type == "event" {
            guard let eventValue = json["event"],
                  JSONSerialization.isValidJSONObject(eventValue),
                  let eventData = try? JSONSerialization.data(withJSONObject: eventValue),
                  let event = try? JSONDecoder().decode(ServerEventPayload.self, from: eventData) else {
                logger.warning("Received malformed engine event frame", category: .websocket)
                return
            }
            #if DEBUG || BETA
            logger.logEvent(type: event.type, sessionId: event.sessionId, data: event.data.map { String(describing: $0.value).prefix(300).description })
            #endif
            let cursor = (json["cursor"] as? UInt64).map(EngineStreamCursor.init(rawValue:))
            let delivery = EngineEventDelivery(
                topic: json["topic"] as? String,
                subscriptionId: json["subscriptionId"] as? String,
                cursor: cursor,
                event: event,
                eventData: eventData
            )
            onEvent?(delivery)
        } else if let id = json["id"] as? String {
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
        } else {
            logger.warning("Received message without id or type", category: .websocket)
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
