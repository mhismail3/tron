import Foundation

@MainActor
extension EngineConnection {
    // MARK: - Reconnection

    func handleDisconnect(
        expectedTask: URLSessionWebSocketTask? = nil,
        expectedGeneration: UInt64? = nil
    ) async {
        if expectedTask != nil || expectedGeneration != nil {
            guard let expectedTask,
                  let expectedGeneration,
                  ownsTransport(expectedTask, generation: expectedGeneration) else {
                logger.debug(
                    "Disconnect ignored for retired transport owner",
                    category: .websocket
                )
                return
            }
        }
        guard !reconnectLoopActive || engineConnectionTask != nil else {
            logger.debug(
                "Disconnect coalesced into the active reconnect owner",
                category: .websocket
            )
            return
        }
        logger.warning("Handling disconnect...", category: .websocket)
        isConnectedFlag = false
        negotiatedMaxMessageSize = nil
        if !isDeployRestarting {
            connectionState = isInBackground
                ? .disconnected
                : .reconnecting(attempt: 1, nextRetrySeconds: 0)
        }
        openedWebSocketTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: EngineConnectionError.notConnected)
        openContinuation = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        retireCurrentTransport(closeCode: .goingAway)
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil

        failPendingRequests(error: EngineConnectionError.connectionFailed("Disconnected"))

        if isInBackground {
            connectionState = .disconnected
            return
        }

        if isDeployRestarting {
            startReconnectOwnership(deployRestart: true)
        } else {
            startReconnectOwnership(deployRestart: false)
        }
    }

    func startReconnectOwnership(deployRestart: Bool) {
        guard !reconnectLoopActive else { return }
        reconnectTaskGeneration &+= 1
        let generation = reconnectTaskGeneration
        reconnectLoopActive = true
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if deployRestart {
                await startDeployReconnection()
            } else {
                await startReconnection()
            }
            finishReconnectOwnership(generation: generation)
        }
    }

    func cancelReconnectOwnership() {
        reconnectTaskGeneration &+= 1
        reconnectLoopActive = false
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func finishReconnectOwnership(generation: UInt64) {
        guard reconnectTaskGeneration == generation else { return }
        let shouldRestartAfterLateDisconnect: Bool
        switch connectionState {
        case .reconnecting, .deployRestarting:
            shouldRestartAfterLateDisconnect = !isConnectedFlag && !isInBackground
        case .connected, .connecting, .disconnected, .failed, .unauthorized:
            shouldRestartAfterLateDisconnect = false
        }
        reconnectLoopActive = false
        reconnectTask = nil
        if shouldRestartAfterLateDisconnect {
            startReconnectOwnership(deployRestart: isDeployRestarting)
        }
    }

    /// Run foreground reconnect probes until the socket returns or parks.
    func startReconnection() async {
        guard !isConnectedFlag && !isInBackground && !Task.isCancelled else { return }
        while !isConnectedFlag && !isInBackground && !Task.isCancelled {
            reconnectAttempts += 1

            if let maxAutomaticAttempts = reconnectPolicy.maxAutomaticAttempts,
               reconnectAttempts > maxAutomaticAttempts {
                logger.warning("Automatic reconnect probe budget exhausted - entering read-only mode", category: .websocket)
                reconnectAttempts = 0
                connectionState = .failed(reason: Self.failedAfterExhaustionReason)
                return
            }

            let reconnectingState = ConnectionState.reconnecting(
                attempt: reconnectAttempts,
                nextRetrySeconds: 0
            )
            let attemptBudget = reconnectPolicy.maxAutomaticAttempts.map { "\($0)" } ?? "unbounded"
            logger.info(
                "Starting reconnect probe \(reconnectAttempts)/\(attemptBudget) (timeout: \(reconnectPolicy.probeTimeout)s)",
                category: .websocket
            )

            await connect(
                openTimeout: reconnectPolicy.probeTimeout,
                stateOnStart: reconnectingState,
                stateOnFailure: reconnectingState
            )

            if isConnectedFlag {
                reconnectAttempts = 0
                return
            }

            if case .unauthorized = connectionState {
                reconnectAttempts = 0
                return
            }

            guard !isInBackground && !Task.isCancelled else { return }

            await waitBeforeNextReconnectProbe(attempt: reconnectAttempts)
        }
    }

    func waitBeforeNextReconnectProbe(attempt: Int) async {
        let totalDelay = max(0, Int(ceil(reconnectPolicy.retryDelay)))
        guard totalDelay > 0 else { return }

        var remainingSeconds = totalDelay
        while remainingSeconds > 0 && !isConnectedFlag && !isInBackground && !Task.isCancelled {
            connectionState = .reconnecting(
                attempt: attempt,
                nextRetrySeconds: remainingSeconds
            )
            try? await Task.sleep(for: .seconds(1))
            remainingSeconds -= 1
        }
    }

    /// Wait for the deploy window, then reconnect with the patient deploy budget.
    func startDeployReconnection() async {
        let maxDeployAttempts = 10
        let deployRetryDelay: TimeInterval = 3.0

        let totalWaitSeconds = max(1, (deployRestartExpectedMs + 5000) / 1000)
        logger.info("Deploy reconnection: waiting \(totalWaitSeconds)s for server restart", category: .websocket)

        var remainingSeconds = totalWaitSeconds
        while remainingSeconds > 0 && !Task.isCancelled {
            connectionState = .deployRestarting(remainingSeconds: remainingSeconds)
            try? await Task.sleep(for: .seconds(1))
            remainingSeconds -= 1
        }

        guard !Task.isCancelled else { return }
        connectionState = .deployRestarting(remainingSeconds: 0)

        reconnectAttempts = 0
        while reconnectAttempts < maxDeployAttempts && !isConnectedFlag && !Task.isCancelled {
            reconnectAttempts += 1
            logger.info("Deploy reconnect attempt \(reconnectAttempts)/\(maxDeployAttempts)", category: .websocket)

            connectionState = .reconnecting(attempt: reconnectAttempts, nextRetrySeconds: 0)
            await connect()

            if isConnectedFlag {
                logger.info("Deploy reconnection successful on attempt \(reconnectAttempts)", category: .websocket)
                isDeployRestarting = false
                deployRestartExpectedMs = 0
                reconnectAttempts = 0
                return
            }

            if reconnectAttempts < maxDeployAttempts && !Task.isCancelled {
                var delay = Int(deployRetryDelay)
                while delay > 0 && !isConnectedFlag && !Task.isCancelled {
                    connectionState = .reconnecting(attempt: reconnectAttempts, nextRetrySeconds: delay)
                    try? await Task.sleep(for: .seconds(1))
                    delay -= 1
                }
            }
        }

        if !isConnectedFlag && !Task.isCancelled {
            logger.warning("Deploy reconnection failed after \(maxDeployAttempts) attempts", category: .websocket)
            isDeployRestarting = false
            deployRestartExpectedMs = 0
            connectionState = .failed(reason: "Server deploy failed - tap to retry")
        }
    }

    /// Manual retry uses the normal open timeout for cold Tailscale/device routes.
    func manualRetry() async {
        guard !isConnectedFlag && !isConnectionInProgress else {
            logger.debug("Manual retry ignored - already connected or connecting", category: .websocket)
            return
        }

        cancelReconnectOwnership()

        reconnectAttempts = 0
        isDeployRestarting = false
        deployRestartExpectedMs = 0
        connectionState = .connecting
        logger.info("Manual retry triggered", category: .websocket)

        await connect(
            openTimeout: Self.manualRetryOpenTimeout,
            stateOnStart: .connecting,
            stateOnFailure: .reconnecting(attempt: 0, nextRetrySeconds: 0)
        )

        if case .unauthorized = connectionState {
            return
        }

        if !isConnectedFlag && !isInBackground {
            startReconnectOwnership(deployRestart: false)
        }
    }
}
