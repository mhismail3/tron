import Foundation
@testable import TronMobileCore
import XCTest
@testable import TronMobile

final class RealGatewayPiBoundaryTests: XCTestCase {
    private struct SessionIDResponse: Decodable { let sessionId: String }
    private struct OperationResponse: Decodable { let operationId: String }
    private struct MutationResponse: Decodable { let answered: Bool }
    private struct SyncResponse: Decodable { let synchronized: Bool }
    private struct CloseResponse: Decodable { let closed: Bool }
    private struct ReceiptParams: Encodable { let commandId: String; let method: String }
    private struct ReceiptResponse: Decodable { let status: String; let result: JSONValue? }
    private struct ModelParams: Encodable { let sessionId: String; let provider: String; let modelId: String; let commandId: String; let expectedRuntimeGeneration: String; let expectedModel: JSONValue }
    private struct UpdatedResponse: Decodable { let updated: Bool }

    private final class MemoryProfileMetadataStore: GatewayProfileMetadataStoring {
        var document: GatewayProfileDocument?
        func load() throws -> GatewayProfileDocument? { document }
        func save(_ document: GatewayProfileDocument) throws { self.document = document }
    }

    private final class MemoryGatewayTokenStore: GatewayTokenStoring {
        var values: [String: String] = [:]
        func save(_ token: String, profileID: String) throws { values[profileID] = token }
        func read(profileID: String) throws -> String? { values[profileID] }
        func delete(profileID: String) throws { values.removeValue(forKey: profileID) }
    }

    private struct CreateParams: Encodable {
        let cwd: String
        let commandId: String
    }

    private struct PromptParams: Encodable {
        let sessionId: String
        let text: String
        let uploadIds: [String]
        let behavior: String?
        let commandId: String
    }

    private struct SessionParams: Encodable { let sessionId: String }
    private struct SessionListParams: Encodable { let cursor: String?; let limit: Int; let scope: String }
    private struct SessionListResponse: Decodable { let sessions: [SessionSummary] }
    private struct SyncParams: Encodable { let sessionId: String; let syncToken: String }
    private struct CloseParams: Encodable { let sessionId: String; let subscriptionToken: String }

    private struct InteractionResponseParams: Encodable {
        let sessionId: String
        let interactionId: String
        let hostEpoch: String
        let presentationRevision: Int
        let value: JSONValue?
        let cancelled: Bool
        let commandId: String
    }

    private enum BoundaryFailure: Error, CustomStringConvertible {
        case invalidFixture(String)
        case timedOut(String)

        var description: String {
            switch self {
            case .invalidFixture(let message), .timedOut(let message): message
            }
        }
    }

    func testStreamsReconnectsAndSettlesExtensionTools() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["TRON_E2E_PORT"],
              let port = Int(portText),
              let code = environment["TRON_E2E_CODE"],
              let workspace = environment["TRON_E2E_WORKSPACE"],
              let proxyToken = environment["TRON_E2E_PROXY_TOKEN"],
              let expectedPiVersion = environment["TRON_E2E_PI_VERSION"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test to provide the real Gateway fixture.")
        }

        let invitation = PairingInvitation(
            host: "127.0.0.1",
            port: port,
            code: code,
            machineId: "tron-ios-e2e",
            label: "Tron iOS E2E"
        )
        let (profile, token) = try await GatewayPairer().pair(invitation, deviceName: "Pi boundary test")
        for (status, expectedCode) in [(401, "unauthenticated"), (403, "forbidden"), (503, "busy")] {
            try await control("reject-upgrade", port: port, token: proxyToken, status: status)
            let rejectedClient = makeClient()
            do {
                _ = try await rejectedClient.connect(profile: profile, token: token)
                throw BoundaryFailure.invalidFixture("Rejected upgrade unexpectedly connected")
            } catch let failure as GatewayFailure {
                XCTAssertEqual(failure.code, expectedCode)
                XCTAssertEqual(failure.retryable, status == 503)
            }
            let diagnostics = await rejectedClient.diagnostics()
            XCTAssertTrue(diagnostics.contains { $0.httpStatusCode == status && $0.platformCode != status })
            await rejectedClient.close()
            try await control("pass", port: port, token: proxyToken)
        }
        let initialClient = makeClient()
        try await control("hold-hello", port: port, token: proxyToken)
        let connecting = Task { try await initialClient.connect(profile: profile, token: token) }
        defer { connecting.cancel() }
        try await control("await-intercepted", port: port, token: proxyToken)
        try await control("pass", port: port, token: proxyToken)
        let firstInfo = try await connecting.value
        XCTAssertEqual(firstInfo.piVersion, expectedPiVersion, "The iOS boundary must exercise the selected Pi runtime")
        try await assertCorrelationKey(client: initialClient)

        // Drop real URLSession traffic without changing the host's network.
        // A received hello must not turn an unanswered read into safe replay.
        try await control("blackhole", port: port, token: proxyToken)
        do {
            _ = try await initialClient.requestValue("system.info", EmptyParams(), timeout: .milliseconds(250))
            throw BoundaryFailure.invalidFixture("Blackholed request unexpectedly received a response")
        } catch is GatewayPossiblySentError { }
        await initialClient.close()
        try await control("pass", port: port, token: proxyToken)
        var probeRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/socket")!)
        probeRequest.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let platformCloseCode: Int
        do {
            // Independent Foundation oracle: some OS releases report 1005
            // (no status) for this peer's 1013. Preserve supplied facts rather
            // than manufacture a code that URLSession did not expose.
            let rawSession = URLSession(configuration: .ephemeral)
            defer { rawSession.invalidateAndCancel() }
            let raw = rawSession.webSocketTask(with: probeRequest)
            raw.resume()
            let hello = try JSONEncoder.gateway.encode(["type": JSONValue.string("hello"), "protocolVersion": .number(7)])
            try await raw.send(.data(hello))
            _ = try await raw.receive()
            try await control("close", port: port, token: proxyToken, closeCode: 1013)
            do { _ = try await raw.receive() } catch { }
            platformCloseCode = raw.closeCode.rawValue
        }
        do {
            // Decoded-size ceiling. The fixture proxy accepts URLSession's
            // permessage-deflate offer, as the Gateway does for paired devices,
            // and CFNetwork's maximumMessageSize bounds only compressed wire
            // bytes, so GatewayFramePolicy checks the inflated frame. A frame at
            // the ceiling must decode through the production socket.
            let socket = GatewaySocketFactory.urlSession.makeConnection(probeRequest, nil)
            let hello = try JSONEncoder.gateway.encode(["type": JSONValue.string("hello"), "protocolVersion": .number(7)])
            try await socket.send(hello)
            _ = try await socket.receive()
            try await control("inject-frame", port: port, token: proxyToken, bytes: GatewayFramePolicy.maximumInboundBytes)
            let atCeiling = try await socket.receive()
            XCTAssertEqual(atCeiling.count, GatewayFramePolicy.maximumInboundBytes)
            XCTAssertNoThrow(try GatewayFramePolicy.validateInboundBytes(atCeiling))
            XCTAssertNoThrow(try JSONDecoder.gateway.decode(GatewayEvent.self, from: atCeiling))
            await socket.close()
        }
        do {
            // One inflated byte over the ceiling retires the client's epoch as a
            // retryable transport failure, like any other rejected frame. Without
            // compression CFNetwork itself fails the receive ("disconnected").
            let oversizedClient = makeClient()
            _ = try await oversizedClient.connect(profile: profile, token: token)
            try await control("inject-frame", port: port, token: proxyToken, bytes: GatewayFramePolicy.maximumInboundBytes + 1)
            let reason = try await waitForDisconnectReason(client: oversizedClient)
            XCTAssertEqual(reason, "frame_too_large", "The simulator app must negotiate compression and reject the inflated frame")
            await oversizedClient.close()
        }
        let remotelyClosedClient = makeClient()
        _ = try await remotelyClosedClient.connect(profile: profile, token: token)
        try await control("close", port: port, token: proxyToken, closeCode: 1013)
        try await waitForDisconnect(client: remotelyClosedClient)
        let remoteDiagnostics = await remotelyClosedClient.diagnostics()
        XCTAssertTrue(remoteDiagnostics.contains { $0.closeCode == (platformCloseCode == 0 ? nil : platformCloseCode) && $0.httpStatusCode == 101 },
                      "Remote close must retain the independent Foundation status \(platformCloseCode)")
        await remotelyClosedClient.close()
        let firstClient = makeClient()
        _ = try await firstClient.connect(profile: profile, token: token)

        let created: SessionIDResponse = try await firstClient.request(
            "session.create",
            CreateParams(cwd: workspace, commandId: UUID().uuidString),
            timeout: .seconds(30)
        )
        try await control("hold-open", port: port, token: proxyToken)
        let opening = Task<GatewaySessionOpenResponse, Error> {
            try await firstClient.request("session.open", SessionParams(sessionId: created.sessionId))
        }
        defer { opening.cancel() }
        try await control("await-intercepted", port: port, token: proxyToken)
        try await control("pass", port: port, token: proxyToken)
        let opened = try await opening.value
        XCTAssertEqual(opened.session.sessionId, created.sessionId)
        try await control("hold-sync", port: port, token: proxyToken)
        let syncing = Task<SyncResponse, Error> {
            try await firstClient.request("session.sync", SyncParams(sessionId: created.sessionId, syncToken: opened.syncToken))
        }
        defer { syncing.cancel() }
        try await control("await-intercepted", port: port, token: proxyToken)
        try await control("pass", port: port, token: proxyToken)
        let synced = try await syncing.value
        XCTAssertTrue(synced.synchronized)
        // Global extension registration and initial model selection are separate
        // SDK phases. Explicitly choose the fixture provider before testing
        // admission; ambient/default credentials must never decide this case.
        let selected: UpdatedResponse = try await firstClient.request("session.setModel", ModelParams(
            sessionId: created.sessionId, provider: "tron-e2e", modelId: "e2e-model", commandId: UUID().uuidString,
            expectedRuntimeGeneration: opened.session.runtimeGeneration, expectedModel: try opened.session.model.map { try JSONValue.encode($0) } ?? .null))
        XCTAssertTrue(selected.updated)
        let configured = try await synchronizedOpen(client: firstClient, sessionID: created.sessionId)
        XCTAssertEqual(configured.session.model?.provider, "tron-e2e")
        XCTAssertEqual(configured.session.model?.id, "e2e-model")
        try await assertAgentInstructions(client: firstClient, sessionID: created.sessionId, workspace: workspace)

        let reconnectPrompt = "continue while disconnected"
        let commandID = UUID().uuidString
        try await control("drop-prompt-response", port: port, token: proxyToken, commandID: commandID)
        do {
        let _: OperationResponse = try await firstClient.request(
            "session.prompt",
            PromptParams(
                sessionId: created.sessionId,
                text: reconnectPrompt,
                uploadIds: [],
                behavior: nil,
                commandId: commandID
            ),
            timeout: .seconds(15)
        )
            throw BoundaryFailure.invalidFixture("Selected accepted response was not lost")
        } catch is GatewayPossiblySentError { }
        await firstClient.close()
        let streamingClient = makeClient()
        _ = try await streamingClient.connect(profile: profile, token: token)
        let receipt: ReceiptResponse = try await streamingClient.request(
            "command.status", ReceiptParams(commandId: commandID, method: "session.prompt")
        )
        XCTAssertEqual(receipt.status, "completed")
        XCTAssertNotNil(receipt.result?.objectValue?["operationId"]?.stringValue)
        _ = try await synchronizedOpen(client: streamingClient, sessionID: created.sessionId)
        try await waitForStreamingText(
            client: streamingClient,
            sessionID: created.sessionId,
            containing: "Streaming response starts now"
        )

        // Admission transfers ownership to the Gateway. Retiring the iOS
        // transport during an observed partial response must not cancel Pi,
        // and a new connection must decode canonical completion rather than
        // rely on buffered events.
        await streamingClient.close()

        let reconnectedClient = makeClient()
        let reconnectedInfo = try await reconnectedClient.connect(profile: profile, token: token)
        XCTAssertEqual(reconnectedInfo.piVersion, expectedPiVersion)
        let recovered = try await waitForSnapshot(
            client: reconnectedClient,
            sessionID: created.sessionId,
            description: "canonical completion after disconnect"
        ) { snapshot in
            snapshot.phase == .idle && Self.text(in: snapshot).contains("Detached response complete")
        }
        XCTAssertTrue(Self.text(in: recovered).contains(reconnectPrompt))
        XCTAssertEqual(recovered.transcript.filter { item in
            guard case .message(let message) = item, message.role == .user else { return false }
            return Self.text(in: item) == reconnectPrompt
        }.count, 1, "Lost response must not execute the accepted prompt twice")

        let toolSubscription = try await synchronizedOpen(
            client: reconnectedClient,
            sessionID: created.sessionId
        )
        let _: OperationResponse = try await reconnectedClient.request(
            "session.prompt",
            PromptParams(
                sessionId: created.sessionId,
                text: "exercise portable tool UI",
                uploadIds: [],
                behavior: nil,
                commandId: UUID().uuidString
            ),
            timeout: .seconds(15)
        )
        try await closeSubscription(
            client: reconnectedClient,
            sessionID: created.sessionId,
            token: toolSubscription.subscriptionToken
        )

        var answeredInteractionIDs = Set<String>()
        for index in 1...3 {
            let (interaction, subscriptionToken) = try await waitForInteraction(
                client: reconnectedClient,
                sessionID: created.sessionId,
                excluding: answeredInteractionIDs,
                description: "extension confirmation \(index)"
            )
            XCTAssertEqual(interaction.method, .select)
            XCTAssertEqual(interaction.title, "Allow this test command?")
            XCTAssertEqual(interaction.options, ["Yes", "No"])
            answeredInteractionIDs.insert(interaction.id)

            let response: MutationResponse = try await reconnectedClient.request(
                "extension.respond",
                InteractionResponseParams(
                    sessionId: created.sessionId,
                    interactionId: interaction.id,
                    hostEpoch: interaction.hostEpoch,
                    presentationRevision: interaction.presentationRevision,
                    value: .string("Yes"),
                    cancelled: false,
                    commandId: UUID().uuidString
                ),
                timeout: .seconds(15)
            )
            XCTAssertTrue(response.answered)
            try await closeSubscription(
                client: reconnectedClient,
                sessionID: created.sessionId,
                token: subscriptionToken
            )
        }

        let settled = try await waitForSnapshot(
            client: reconnectedClient,
            sessionID: created.sessionId,
            description: "three-tool canonical settlement"
        ) { snapshot in
            snapshot.phase == .idle
                && Self.text(in: snapshot).contains("Tool response complete after all three tools.")
        }
        let messages = settled.transcript.compactMap { item -> MessageTranscriptItem? in
            guard case .message(let message) = item else { return nil }
            return message
        }
        let expectedToolIDs: Set<String> = ["e2e-tool-1", "e2e-tool-2", "e2e-tool-3"]
        let toolCalls = messages.flatMap(\.content).filter { $0.type == .toolCall && $0.toolCallId != nil }
        XCTAssertEqual(Set(toolCalls.compactMap(\.toolCallId)), expectedToolIDs)
        XCTAssertEqual(Set(toolCalls.compactMap(\.groupId)).count, 1)
        XCTAssertTrue(toolCalls.allSatisfy { $0.groupCount == 3 && $0.groupFinalized == true })
        XCTAssertEqual(
            Set(messages.filter { $0.role == .toolResult }.compactMap(\.toolCallId)),
            expectedToolIDs
        )
        await reconnectedClient.close()
        await firstClient.close()

        try await Self.exerciseForegroundReconnect(
            profile: profile,
            token: token,
            port: port,
            proxyToken: proxyToken,
            sessionID: created.sessionId
        )
        let blackholeRecords = try await Self.exerciseBlackholedReconnect(
            profile: profile,
            token: token,
            port: port,
            proxyToken: proxyToken
        )
        let foregroundRecords = try await Self.exerciseForegroundBlackholedReconnect(
            profile: profile,
            token: token,
            port: port,
            proxyToken: proxyToken
        )
        let longOutageRecords = try await Self.exerciseLongBlackholedReconnect(
            profile: profile,
            token: token,
            port: port,
            proxyToken: proxyToken
        )
        let attachment = XCTAttachment(string: (blackholeRecords + foregroundRecords + longOutageRecords).map { record in
            "\(record.timestamp) \(record.level) \(record.event) durationMs=\(record.durationMs ?? -1) outcome=\(record.outcome ?? "-") \(record.message)"
        }.joined(separator: "\n"))
        attachment.name = "phone-connection-records"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The O-6b shape: the socket is already live in the foreground, the route is
    /// blackholed under it, and the phone itself sees the loss through its
    /// liveness probe. The episode is therefore opened at the loss, before the
    /// first recovery attempt, which is the silent gap this leg exists to
    /// measure. The app stays foregrounded throughout: no scene transition opens
    /// or ends anything.
    @MainActor
    private static func exerciseForegroundBlackholedReconnect(
        profile: GatewayProfile,
        token: String,
        port: Int,
        proxyToken: String
    ) async throws -> [AppLogRecord] {
        let memoryTokens = MemoryGatewayTokenStore()
        let profiles = GatewayProfileStore(metadata: MemoryProfileMetadataStore(), tokens: memoryTokens)
        try profiles.save(profile, token: token)
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "o-4-foreground-blackhole-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let client = GatewayClient()
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { try? memoryTokens.read(profileID: $0.id) },
            appLog: appLog
        )
        do {
            lifecycle.notePathHint(satisfied: true)
            await lifecycle.start()
            guard lifecycle.connectionState == .connected else {
                throw BoundaryFailure.invalidFixture("The lifecycle did not connect before the foreground blackhole")
            }
            guard try await Self.waitForAttemptCount(1, in: appLog, deadline: .seconds(15)) else {
                throw BoundaryFailure.invalidFixture("The initial attempt was not recorded")
            }
            let attemptsBeforeBlackhole = await Self.recordCount(in: appLog, event: "gateway.attempt")

            // The phone's own projection of a transport loss, as AppModel does in
            // production: the loss opens the episode and asks for one immediate
            // attempt. The client's liveness probe is what detects a blackholed
            // socket, because the proxy fabricates no pong.
            let lossSeen = LossInstant()
            let observer = Task {
                for await delivery in client.events where delivery.event.topic == "transport.disconnected" {
                    let reason = delivery.event.payload.objectValue?["reason"]?.stringValue ?? "disconnected"
                    let connectionID = delivery.connectionID
                    await lossSeen.record(code: reason)
                    await lifecycle.noteDisconnected(
                        connectionID: connectionID,
                        reason: reason
                    )
                    lifecycle.requestReconnect(immediate: true)
                }
            }
            defer { observer.cancel() }

            try await Self.control("blackhole", port: port, token: proxyToken)
            guard try await Self.waitForAttemptCount(
                attemptsBeforeBlackhole + 1, in: appLog, deadline: .seconds(60)
            ) else {
                throw BoundaryFailure.timedOut("The phone did not see the foreground loss and attempt recovery")
            }
            try await Self.control("pass", port: port, token: proxyToken)
            guard let admission = lifecycle.generationAdmission,
                  await lifecycle.waitForConnected(
                    until: ContinuousClock().now + .seconds(60),
                    admission: admission
                  ) else {
                throw BoundaryFailure.timedOut("The lifecycle did not reconnect after the foreground blackhole")
            }
            let records = try await Self.waitForEpisode(
                in: appLog, deadline: ContinuousClock().now + .seconds(20)
            )
            let attempts = Array(
                records.filter { $0.event == "gateway.attempt" }
                    .dropFirst(attemptsBeforeBlackhole)
            )
            let resolved = records.filter {
                $0.event == "connection.episode" && $0.message.contains("endedBy=connected")
            }
            XCTAssertEqual(resolved.count, 1, "One foreground outage resolves in one episode record")
            XCTAssertGreaterThanOrEqual(attempts.count, 2, "Every attempt of the outage must be on the timeline")
            XCTAssertEqual(attempts.filter { $0.outcome == "success" }.count, 1)
            let episode = try XCTUnwrap(resolved.first)
            XCTAssertTrue(episode.message.contains("attempts=\(attempts.count)"))
            // The loss the phone saw opens the episode; the first recovery attempt
            // starts about a millisecond later, so both bounds below are coarse on
            // purpose: an episode dated by that attempt would satisfy them too.
            // They catch a start before the loss or after the attempt's end.
            let observedLoss = await lossSeen.instant
            let lossAt = try XCTUnwrap(observedLoss, "The phone must record the loss it saw")
            let observedLossCode = await lossSeen.lossCode
            let lossCode = try XCTUnwrap(
                observedLossCode,
                "The phone must record the loss code it saw"
            )
            let startedAt = try XCTUnwrap(
                Self.episodeDate("startedAt", in: episode.message),
                "The episode must report its start"
            )
            XCTAssertGreaterThanOrEqual(startedAt, lossAt.addingTimeInterval(-1))
            let firstAttemptAt = try XCTUnwrap(GatewayTimestamp.parse(attempts[0].timestamp))
            XCTAssertLessThanOrEqual(startedAt, firstAttemptAt)
            // Only the loss opens the episode with a cause, and only
            // `noteDisconnected` contributes the loss's own code; the codes after
            // it come from the failed attempts. An episode opened by the first
            // failed attempt instead of by the loss would not name it first, which
            // is the evidence this leg exists for.
            let causes = try XCTUnwrap(
                Self.episodeCauses(in: episode.message),
                "The episode must report its causes"
            )
            XCTAssertEqual(causes.first, GatewayDiagnosticFailure.normalizedCode(lossCode))
            let outage = records
            await lifecycle.teardown()
            await client.close()
            return outage
        } catch {
            await lifecycle.teardown()
            await client.close()
            throw error
        }
    }

    /// E-3c: the two lanes the phone races at home, dialed against the fixture
    /// Gateway's own pinned LAN listener (`scripts/ios-gateway-e2e-test run-lan`
    /// starts it with the lane on). The advertised endpoint and pin come from the
    /// pairing response, the lane serves its own certificate and WebSocket, and
    /// the pin is checked by the socket's own trust evaluation, so every leg runs
    /// production code end to end.
    ///
    func testSharedLinkUploadAndWebSocketLiveness() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["TRON_E2E_PORT"],
              let port = Int(portText),
              let code = environment["TRON_E2E_CODE"],
              let proxyToken = environment["TRON_E2E_PROXY_TOKEN"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test to provide the real Gateway fixture.")
        }
        let invitation = PairingInvitation(
            host: "127.0.0.1",
            port: port,
            code: code,
            machineId: "tron-ios-e2e",
            label: "Tron iOS E2E"
        )
        let (profile, token) = try await GatewayPairer().pair(invitation, deviceName: "Shared link test")
        let client = makeClient()
        _ = try await client.connect(profile: profile, token: token)
        let connectedID = await client.activeConnectionID()
        let originalConnectionID = try XCTUnwrap(connectedID)
        let payload = Data(repeating: 0x78, count: 298_013)

        // One FIFO shaper owns the actual HTTP and WebSocket proxy paths. This
        // test-only aggregate rate keeps the body in flight long enough to
        // observe its actual overlap with liveness traffic. No traffic receives
        // priority, and the production 8 s pong deadline is unchanged.
        try await control(
            "shape", port: port, token: proxyToken,
            rateBytesPerSecond: 12_288, latencyMilliseconds: 30, maximumQueuedBytes: 1_048_576
        )
        let clock = ContinuousClock()
        let uploadStarted = clock.now
        let upload = Task {
            let id = try await client.upload(name: "synthetic.bin", mimeType: "application/octet-stream", data: payload)
            return (id, uploadStarted.duration(to: clock.now))
        }
        let observationDeadline = clock.now + .seconds(35)
        var rpcCount = 0
        while clock.now < observationDeadline {
            _ = try await client.requestValue("system.info", EmptyParams(), timeout: .seconds(8))
            rpcCount += 1
            try await Task.sleep(for: .seconds(2))
        }
        XCTAssertGreaterThanOrEqual(rpcCount, 8)
        let (firstUploadID, completedUploadDuration) = try await upload.value
        XCTAssertFalse(firstUploadID.isEmpty)
        let uploadDuration = completedUploadDuration.components
        let uploadDurationMilliseconds = Int(uploadDuration.seconds * 1_000 + uploadDuration.attoseconds / 1_000_000_000_000_000)
        XCTAssertGreaterThanOrEqual(uploadDurationMilliseconds, 4_000, "The transfer should experience the declared aggregate 64 KiB/s capacity")
        XCTAssertLessThan(uploadDurationMilliseconds, 32_000, "The bounded healthy transfer must complete within its test-only phase deadline")
        let afterShapedUploadID = await client.activeConnectionID()
        XCTAssertEqual(afterShapedUploadID, originalConnectionID)

        let shaped = try await controlValue("link-stats", port: port, token: proxyToken)
        let heartbeatTimeline = shaped.objectValue?["clientHeartbeatTimeline"]?.arrayValue ?? []
        let completedHeartbeats = heartbeatTimeline.compactMap { item -> (enqueuedMs: Int, pongForwardedMs: Int)? in
            guard let event = item.objectValue,
                  let enqueuedMs = event["enqueuedMs"]?.intValue,
                  event["forwardedMs"]?.intValue != nil,
                  event["gatewayPongMs"]?.intValue != nil,
                  let pongForwardedMs = event["appPongForwardedMs"]?.intValue else { return nil }
            return (enqueuedMs, pongForwardedMs)
        }
        guard completedHeartbeats.count >= 2 else {
            throw BoundaryFailure.timedOut("The upload did not overlap two complete heartbeat cycles")
        }
        let observedHeartbeatIntervalMs = completedHeartbeats[completedHeartbeats.count - 1].enqueuedMs
            - completedHeartbeats[completedHeartbeats.count - 2].enqueuedMs
        XCTAssertGreaterThan(observedHeartbeatIntervalMs, 0)
        let observedForwardedPings = heartbeatTimeline.filter { item in
            item.objectValue?["forwardedMs"]?.intValue != nil
        }.count
        let observedForwardedPongs = heartbeatTimeline.filter { item in
            item.objectValue?["appPongForwardedMs"]?.intValue != nil
        }.count
        XCTAssertEqual(shaped.objectValue?["forwardedWebSocketPings"]?.intValue, observedForwardedPings)
        XCTAssertEqual(shaped.objectValue?["forwardedWebSocketPongs"]?.intValue, observedForwardedPongs)
        XCTAssertGreaterThanOrEqual(observedForwardedPings, 2)
        XCTAssertGreaterThanOrEqual(observedForwardedPongs, 2)
        let heartbeatRTTs = shaped.objectValue?["heartbeatRoundTripMilliseconds"]?.arrayValue?.compactMap(\.intValue) ?? []
        XCTAssertGreaterThanOrEqual(heartbeatRTTs.count, 2)
        XCTAssertTrue(heartbeatRTTs.allSatisfy { $0 < 8_000 }, "Enqueue-to-Gateway-pong delay, including FIFO wait, must meet the unchanged 8 s client bound")
        let bodyInterval = try XCTUnwrap(shaped.objectValue?["uploadBodyTransfers"]?.arrayValue?.first?.objectValue)
        let bodyStartMs = try XCTUnwrap(bodyInterval["startMs"]?.intValue)
        let bodyEndMs = try XCTUnwrap(bodyInterval["endMs"]?.intValue)
        XCTAssertEqual(bodyInterval["bytes"]?.intValue, payload.count)
        XCTAssertGreaterThan(bodyEndMs, bodyStartMs)
        XCTAssertGreaterThan(bodyEndMs - bodyStartMs, 2 * observedHeartbeatIntervalMs,
                             "The observed body transfer should span more than two measured heartbeat intervals")
        let overlappingHeartbeatCount = heartbeatTimeline.filter { item in
            guard let event = item.objectValue,
                  let pingForwardedMs = event["forwardedMs"]?.intValue,
                  let pongForwardedMs = event["appPongForwardedMs"]?.intValue,
                  let gatewayPongMs = event["gatewayPongMs"]?.intValue else { return false }
            return pingForwardedMs >= bodyStartMs && pingForwardedMs <= bodyEndMs
                && gatewayPongMs >= bodyStartMs && gatewayPongMs <= bodyEndMs
                && pongForwardedMs >= bodyStartMs && pongForwardedMs <= bodyEndMs
        }.count
        XCTAssertGreaterThanOrEqual(overlappingHeartbeatCount, 1,
                                    "Require an actually forwarded client ping and Gateway pong both observed/forwarded during the upload-body interval")
        XCTAssertEqual(shaped.objectValue?["uploadBodyBytes"]?.intValue, payload.count)
        XCTAssertGreaterThanOrEqual(shaped.objectValue?["dispatchedRPCs"]?.intValue ?? 0, rpcCount)
        XCTAssertGreaterThanOrEqual(shaped.objectValue?["settledRPCs"]?.intValue ?? 0, rpcCount)
        XCTAssertEqual(shaped.objectValue?["originalAuthority"]?.stringValue, "127.0.0.1:\(port)")
        XCTAssertEqual(shaped.objectValue?["scheduleOverflows"]?.intValue, 0)
        XCTAssertLessThanOrEqual(shaped.objectValue?["queueHighWaterBytes"]?.intValue ?? Int.max, 1_048_576)
        XCTAssertEqual(shaped.objectValue?["queuedPayloadBytes"]?.intValue, 0)
        let initialStaging = try await client.requestValue("uploads.status", EmptyParams())
        XCTAssertEqual(initialStaging.objectValue?["unclaimedCount"]?.intValue, 1)

        // The Gateway consumes and stages a second real body, but the proxy
        // holds its HTTP response. RPCs and heartbeat control frames still use
        // the same FIFO schedule; the held HTTP response gets no priority.
        try await control("hold-http-response", port: port, token: proxyToken)
        let heldUpload = Task { try await client.upload(name: "held.bin", mimeType: "application/octet-stream", data: Data(repeating: 0x68, count: 32_768)) }
        try await control("await-http-held", port: port, token: proxyToken)
        let heldStaging = try await client.requestValue("uploads.status", EmptyParams())
        XCTAssertEqual(heldStaging.objectValue?["unclaimedCount"]?.intValue, 2,
                       "The Gateway must commit the actual body before its held HTTP receipt is released")
        let heldConnectionID = await client.activeConnectionID()
        _ = try await client.requestValue("system.info", EmptyParams(), timeout: .seconds(8))
        let stillHeldConnectionID = await client.activeConnectionID()
        XCTAssertEqual(stillHeldConnectionID, heldConnectionID)
        try await control("pass", port: port, token: proxyToken)
        let secondUploadID = try await heldUpload.value
        XCTAssertFalse(secondUploadID.isEmpty)
        try await client.discardUpload(firstUploadID)
        try await client.discardUpload(secondUploadID)
        let afterCleanup = try await client.requestValue("uploads.status", EmptyParams())
        XCTAssertEqual(afterCleanup.objectValue?["unclaimedCount"]?.intValue, 0)
        let heldStagedCount = heldStaging.objectValue?["unclaimedCount"]?.intValue ?? -1

        // A common-path interruption is an expected outage control, not a RED:
        // both protocols are blackholed, then the same original authority works
        // again once the test-owned path is restored.
        try await control("blackhole", port: port, token: proxyToken, httpBlackhole: true)
        var commonLinkTimeoutObserved = false
        do {
            _ = try await client.requestValue("system.info", EmptyParams(), timeout: .milliseconds(350))
            XCTFail("An unavailable common link unexpectedly returned an RPC")
        } catch is GatewayPossiblySentError { commonLinkTimeoutObserved = true }
        XCTAssertTrue(commonLinkTimeoutObserved)
        try await control("pass", port: port, token: proxyToken)
        _ = try await client.requestValue("system.info", EmptyParams(), timeout: .seconds(8))
        let afterRecoveryConnectionID = await client.activeConnectionID()
        XCTAssertEqual(afterRecoveryConnectionID, originalConnectionID)

        // Separate below-frame-limit diagnostic JSON control, without HTTP
        // traffic or shaping, using synthetic content only.
        try await control("unshape", port: port, token: proxyToken)
        let exported = try await client.requestValue("system.logs.export", JSONValue.object([
            "commandId": .string(UUID().uuidString),
            "content": .string(String(repeating: "x", count: 262_144)),
        ]), timeout: .seconds(15))
        XCTAssertFalse(exported.objectValue?.isEmpty ?? true)
        let logsWire = try await controlValue("link-stats", port: port, token: proxyToken)
        let logsFrameBytes = logsWire.objectValue?["logsExportRequestBytes"]?.intValue ?? 0
        XCTAssertGreaterThan(logsFrameBytes, 262_144)
        XCTAssertLessThan(logsFrameBytes, 1_048_576)
        XCTAssertGreaterThan(logsWire.objectValue?["logsExportResponseBytes"]?.intValue ?? 0, 0)
        let diagnostics = await client.diagnostics()
        XCTAssertFalse(diagnostics.contains { $0.outcome == .failure && $0.stage == .liveness })
        let finalConnectionID = await client.activeConnectionID()
        XCTAssertEqual(finalConnectionID, originalConnectionID)
        let attachment = XCTAttachment(string: [
            "authority=paired fixture Gateway through owned shared proxy",
            "uploadBytes=\(payload.count) uploadDurationMs=\(uploadDurationMilliseconds) periodicRPCs=\(rpcCount)",
            "observedHeartbeatIntervalMs=\(observedHeartbeatIntervalMs) uploadBodyIntervalMs=\(bodyStartMs)-\(bodyEndMs) uploadHeartbeatOverlaps=\(overlappingHeartbeatCount)",
            "originalConnectionID=\(originalConnectionID)",
            "heldHTTPResponse=held; stagedUploads=\(heldStagedCount); RPC=healthy; connectionPreserved=\(stillHeldConnectionID == heldConnectionID)",
            "commonLinkOutage=expectedPossiblySentTimeout; restoredRPC=success; connectionPreserved=\(afterRecoveryConnectionID == originalConnectionID)",
            "proxySchedule=\(shaped)",
            "largeLogsInputBytes=262144 wireFrameBytes=\(logsFrameBytes) result=\(exported.objectValue?.keys.sorted().joined(separator: ",") ?? "none")",
            "stagingCleanup=pending:0",
        ].joined(separator: "\n"))
        attachment.name = "shared-link-transport-observations"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Done when: the saved leg blackholed for 90 s is invisible to the
    /// connection the LAN lane carries — WebSocket and HTTP routes alike; a
    /// blocked LAN lane falls back to the saved lane within the stagger plus one
    /// handshake and retires its own socket; and a pin that does not match the
    /// served certificate sends no credential.
    func testRacesLanAndTailscaleLanes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["TRON_E2E_PORT"],
              let port = Int(portText),
              let code = environment["TRON_E2E_CODE"],
              let proxyToken = environment["TRON_E2E_PROXY_TOKEN"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test run-lan to provide the fixture Gateway.")
        }
        let invitation = PairingInvitation(
            host: "127.0.0.1",
            port: port,
            code: code,
            machineId: "tron-ios-e2e",
            label: "Tron iOS E2E"
        )
        let (paired, token) = try await GatewayPairer().pair(invitation, deviceName: "LAN lane race")
        let advertised = try XCTUnwrap(paired.lanEndpoints.first, "The fixture Gateway must advertise its LAN lane")
        let pin = try XCTUnwrap(paired.lanPin, "The fixture Gateway must advertise the LAN lane's pin")
        XCTAssertEqual(Data(base64Encoded: pin)?.count, 32, "The advertised pin must be a 256-bit public-key pin")
        NSLog("e-3c: LAN lane advertised at \(advertised.host):\(advertised.port)")
        // The lane is dialed only on Wi-Fi (D-5). The simulator reports this Mac's
        // wired path, so the phone's own path fact is an input of this leg: the
        // subject is the race's behavior on Wi-Fi, not this host's uplink.
        let onWifi: @Sendable () -> String? = { "wifi,other" }
        try await control("pass", port: port, token: proxyToken)

        // (1) A phone on Wi-Fi reaches its Mac over the LAN lane.
        let lanClient = makeClient(networkPath: onWifi)
        _ = try await lanClient.connect(profile: paired, token: token)
        let lanHandshakes = await successfulHandshakes(of: lanClient)
        XCTAssertEqual(lanHandshakes.count, 1)
        XCTAssertEqual(lanHandshakes.first?.handshake?.transport, "lan")

        // (2) The saved lane blackholed for 90 s is invisible to that
        // connection: the proxy drops every byte the other lane would carry —
        // WebSocket frames and plain HTTP — while the LAN socket keeps
        // answering. The upload is the HTTP half: the blackholed saved lane
        // cannot answer it at all, so the route that returns an id is the
        // winning LAN lane, exactly as live view and media use it.
        try await control("blackhole", port: port, token: proxyToken, httpBlackhole: true)
        NSLog("e-3c: 90 s blackhole of the saved lane starts over a live LAN connection")
        let outageStarted = ContinuousClock().now
        var uploads = 0
        while outageStarted.duration(to: ContinuousClock().now) < .seconds(90) {
            _ = try await lanClient.requestValue("system.info", EmptyParams(), timeout: .seconds(10))
            let uploadID = try await lanClient.upload(
                name: "e-3c-blackhole.txt",
                mimeType: "text/plain",
                data: Data("through a blackholed saved lane".utf8)
            )
            XCTAssertFalse(uploadID.isEmpty, "The upload route must answer over the winning lane")
            uploads += 1
            try await Task.sleep(for: .seconds(5))
        }
        XCTAssertGreaterThan(uploads, 8, "The HTTP leg must run through the blackhole, not around it")
        try await control("pass", port: port, token: proxyToken)
        let survivingHandshakes = await successfulHandshakes(of: lanClient)
        XCTAssertEqual(survivingHandshakes.count, 1, "A blackholed saved lane must not reconnect the LAN connection")
        XCTAssertEqual(survivingHandshakes.first?.handshake?.transport, "lan")
        let lanDiagnostics = await lanClient.diagnostics()
        XCTAssertFalse(lanDiagnostics.contains { $0.outcome == .failure && $0.stage == .helloReceive })
        await lanClient.close()
        NSLog("e-3c: the 90 s blackhole left the LAN connection up")

        // (3) A blocked LAN lane costs the stagger plus one handshake: the lane
        // TCP-connects but never answers TLS, so the saved lane wins, and the
        // losing LAN socket is retired instead of hanging on.
        let blockedLane = try HangingLanLane()
        defer { blockedLane.close() }
        var blocked = paired
        blocked.lanEndpoints = [try XCTUnwrap(GatewayLanEndpoint(host: "127.0.0.1", port: blockedLane.port))]
        let blockedClient = makeClient(networkPath: onWifi)
        let attemptStarted = ContinuousClock().now
        _ = try await blockedClient.connect(profile: blocked, token: token)
        let fallbackElapsed = attemptStarted.duration(to: ContinuousClock().now)
        let fallbackHandshakes = await successfulHandshakes(of: blockedClient)
        XCTAssertEqual(fallbackHandshakes.first?.handshake?.transport, "tailscale",
                       "A blocked LAN lane must fall back to the saved endpoint")
        XCTAssertGreaterThanOrEqual(fallbackElapsed, .milliseconds(240),
                                    "The saved lane must wait out the 250 ms stagger for a LAN lane that is still dialing")
        XCTAssertLessThan(fallbackElapsed, .milliseconds(1_750),
                          "The saved lane must win within the LAN stagger (250 ms) plus one handshake")
        XCTAssertTrue(
            blockedLane.dialWasMadeAndClosed(within: .seconds(3)),
            "The losing LAN socket must be retired, not left dialing"
        )
        // The winner cancelled that lane, so there is no answer to report: a
        // retired lane is not a LAN failure (its focused case is
        // `GatewayClientLanLaneTests.failedLanLaneWakesTheStagger`).
        let blockedLaneLosses = await lanFailures(of: blockedClient)
        XCTAssertTrue(blockedLaneLosses.isEmpty, "A lane the winner retired must not be recorded as a LAN failure")
        await blockedClient.close()

        // (4) A pin that does not match the served certificate sends no
        // credential: the LAN lane is refused at its trust challenge, before the
        // upgrade request that carries the device token is written, and the saved
        // lane carries the connection.
        var mismatched = paired
        mismatched.lanPin = Data(repeating: 0x5a, count: 32).base64EncodedString()
        let mismatchedClient = makeClient(networkPath: onWifi)
        _ = try await mismatchedClient.connect(profile: mismatched, token: token)
        let mismatchedHandshakes = await successfulHandshakes(of: mismatchedClient)
        XCTAssertEqual(mismatchedHandshakes.first?.handshake?.transport, "tailscale",
                       "A lane whose pin is refused must not carry the connection")
        let refusals = await lanFailures(of: mismatchedClient)
        let refusedPin = try XCTUnwrap(
            refusals.first { $0.reason == .lanPinMismatch },
            "The LAN lane must report the refused pin"
        )
        XCTAssertEqual(refusedPin.handshake?.transportOpened, false,
                       "A refused pin must leave the transport unopened, so no credential-bearing request was written")
        await mismatchedClient.close()
    }

    /// The successful hello of each epoch this client installed, newest last.
    private func successfulHandshakes(of client: GatewayClient) async -> [GatewayConnectionDiagnostic] {
        await client.diagnostics()
            .filter { $0.outcome == .success && $0.stage == .helloReceive }
            .sorted { $0.sequence < $1.sequence }
    }

    /// The LAN lane's failures on this client, in the order they were recorded.
    private func lanFailures(of client: GatewayClient) async -> [GatewayConnectionDiagnostic] {
        await client.diagnostics()
            .filter { $0.outcome == .failure && $0.handshake?.transport == "lan" }
            .sorted { $0.sequence < $1.sequence }
    }

    /// A LAN lane that TCP-connects but never answers TLS: the socket binds and
    /// listens but never accepts, so a dial completes its TCP handshake and then
    /// waits for a TLS answer that never comes — a client-isolated network or a
    /// silently dropped packet, rather than the immediate refusal a closed port
    /// gives. It also proves what the dial did: that a connection arrived, and
    /// that the losing socket was retired rather than left dialing.
    private final class HangingLanLane {
        private let descriptor: Int32
        let port: Int

        init() throws {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw BoundaryFailure.invalidFixture("The blocked lane needs a socket") }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(descriptor, 1) == 0 else {
                Darwin.close(descriptor)
                throw BoundaryFailure.invalidFixture("The blocked lane could not listen")
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    getsockname(descriptor, socketAddress, &length)
                }
            }
            guard named == 0 else {
                Darwin.close(descriptor)
                throw BoundaryFailure.invalidFixture("The blocked lane could not read its port")
            }
            self.descriptor = descriptor
            self.port = Int(UInt16(bigEndian: address.sin_port))
        }

        /// Whether a dial reached this lane and then closed again: the queued
        /// connection, the bytes it sent, and the end of the stream it left —
        /// which is the losing socket being retired rather than left open.
        func dialWasMadeAndClosed(within timeout: Duration) -> Bool {
            var listener = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&listener, 1, Self.milliseconds(timeout)) > 0 else { return false }
            let accepted = accept(descriptor, nil, nil)
            guard accepted >= 0 else { return false }
            defer { Darwin.close(accepted) }
            let deadline = ContinuousClock().now.advanced(by: timeout)
            var sawBytes = false
            while ContinuousClock().now < deadline {
                var readable = pollfd(fd: accepted, events: Int16(POLLIN), revents: 0)
                guard poll(&readable, 1, Self.milliseconds(.seconds(1))) > 0 else { return false }
                var chunk = [UInt8](repeating: 0, count: 4_096)
                let received = recv(accepted, &chunk, chunk.count, 0)
                if received > 0 { sawBytes = true; continue }
                // 0 is the peer's close; an error is the peer's reset. Both mean
                // this dial is over.
                return sawBytes
            }
            return false
        }

        func close() { Darwin.close(descriptor) }

        private static func milliseconds(_ duration: Duration) -> Int32 {
            Int32(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
    }

    /// C-1: a 90 s blackhole under a foreground app. Recovery must keep
    /// attempting at its scheduled cadence for the whole outage, resolve within
    /// one attempt of the path's return, and never report `reconnect.stalled`.
    /// The projection owner stalls its mounted restoration after the handshake
    /// that ends the outage, so the leg also proves the second outage is answered
    /// by a new attempt instead of a loop parked in projection work.
    @MainActor
    private static func exerciseLongBlackholedReconnect(
        profile: GatewayProfile,
        token: String,
        port: Int,
        proxyToken: String
    ) async throws -> [AppLogRecord] {
        let memoryTokens = MemoryGatewayTokenStore()
        let profiles = GatewayProfileStore(metadata: MemoryProfileMetadataStore(), tokens: memoryTokens)
        try profiles.save(profile, token: token)
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "c-1-long-blackhole-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let client = GatewayClient()
        let projection = StallingRestoreProjection()
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { try? memoryTokens.read(profileID: $0.id) },
            appLog: appLog
        )
        lifecycle.delegate = projection
        do {
            lifecycle.notePathHint(satisfied: true)
            await lifecycle.start()
            guard lifecycle.connectionState == .connected else {
                throw BoundaryFailure.invalidFixture("The lifecycle did not connect before the long blackhole")
            }
            guard try await Self.waitForAttemptCount(1, in: appLog, deadline: .seconds(15)) else {
                throw BoundaryFailure.invalidFixture("The initial attempt was not recorded")
            }
            let attemptsBeforeBlackhole = await Self.recordCount(in: appLog, event: "gateway.attempt")

            // The phone's own projection of a transport loss, as AppModel does in
            // production: the loss opens the episode and asks for one immediate
            // attempt.
            let observer = Task {
                for await delivery in client.events where delivery.event.topic == "transport.disconnected" {
                    let reason = delivery.event.payload.objectValue?["reason"]?.stringValue ?? "disconnected"
                    await lifecycle.noteDisconnected(
                        connectionID: delivery.connectionID,
                        reason: reason
                    )
                    lifecycle.requestReconnect(immediate: true)
                }
            }
            defer { observer.cancel() }

            // The mounted restoration after the outage's successful handshake
            // never finishes until this leg releases it.
            projection.stallNextRestore()

            try await Self.control("blackhole", port: port, token: proxyToken)
            NSLog("c-1: 90 s blackhole starts")
            let blackholeAt = ContinuousClock().now
            // The outage lasts a full 90 s. Recovery attempts every transport
            // deadline plus one bounded backoff, so each gap between two attempt
            // starts stays inside that cadence.
            let cadenceBoundMs = 35_000
            var startsMs: [Int] = []
            while blackholeAt.duration(to: ContinuousClock().now) < .seconds(90) {
                try await Task.sleep(for: .seconds(1))
                startsMs = await Self.attemptStarts(in: appLog, droppingFirst: attemptsBeforeBlackhole)
                    .map { $0 }
                if let largest = Self.largestGap(startsMs), largest > cadenceBoundMs {
                    XCTFail("A blackholed attempt gap of \(largest) ms exceeds the scheduled cadence")
                    break
                }
            }
            startsMs = await Self.attemptStarts(in: appLog, droppingFirst: attemptsBeforeBlackhole)
            XCTAssertGreaterThanOrEqual(
                startsMs.count, 3,
                "Recovery must keep attempting for the whole 90 s outage"
            )
            let stallCount = await Self.recordCount(in: appLog, event: "reconnect.stalled")
            XCTAssertEqual(stallCount, 0, "A parked or busy episode must not be reported as a stall")

            // The path returns: the first attempt that starts after it must be the
            // one that connects.
            let restoredAt = Date()
            NSLog("c-1: 90 s blackhole ends, restoring the path")
            try await Self.control("pass", port: port, token: proxyToken)
            guard let admission = lifecycle.generationAdmission,
                  await lifecycle.waitForConnected(
                    until: ContinuousClock().now + .seconds(60),
                    admission: admission
                  ) else {
                throw BoundaryFailure.timedOut("The lifecycle did not reconnect after the long blackhole")
            }
            let connectedAt = Date()
            NSLog("c-1: reconnected after the 90 s blackhole")
            let outageRecords = await appLog.snapshot()
            let attempts = Array(
                outageRecords.filter { $0.event == "gateway.attempt" }
                    .dropFirst(attemptsBeforeBlackhole)
            )
            // A record is written when its attempt ends, so the attempt that was
            // in flight when the path returned is recorded after it and still
            // burns its hello deadline. "Within one attempt of the path
            // returning" therefore means: at most that one failure, and the next
            // attempt connects promptly.
            let attemptsAfterReturn = attempts.filter { record in
                guard let at = GatewayTimestamp.parse(record.timestamp) else { return false }
                return at >= restoredAt.addingTimeInterval(-1)
            }
            XCTAssertGreaterThanOrEqual(attemptsAfterReturn.count, 1, "The restored path must be attempted")
            let failuresAfterReturn = attemptsAfterReturn.prefix { $0.outcome == "failure" }.count
            XCTAssertLessThanOrEqual(
                failuresAfterReturn, 1,
                "The path's return may cost only the attempt already in flight"
            )
            XCTAssertEqual(
                attemptsAfterReturn.first { $0.outcome == "success" }?.message.contains("stageReached=connected"),
                true,
                "The attempt after the in-flight one must connect"
            )
            XCTAssertLessThanOrEqual(
                connectedAt.timeIntervalSince(restoredAt), 25,
                "Recovery from the path's return took longer than one attempt"
            )

            // The handshake that ended the outage handed restoration to its
            // presentation owner, where it is still running. A fresh blackhole
            // must be answered by a new attempt while that restoration runs,
            // which is exactly what a loop parked in projection work cannot do.
            NSLog("c-1: outage resolved, waiting for the stalled restoration")
            guard await projection.waitUntilRestoring(deadline: .seconds(30)) else {
                throw BoundaryFailure.invalidFixture(
                    "The handshake that ended the outage did not start its mounted restoration"
                )
            }
            NSLog("c-1: restoration stalled, blackholing the live socket")
            try await Self.control("blackhole", port: port, token: proxyToken)
            let attemptsBeforeSecondOutage = await Self.recordCount(in: appLog, event: "gateway.attempt")
            guard try await Self.waitForAttemptCount(
                attemptsBeforeSecondOutage + 1, in: appLog, deadline: .seconds(40)
            ) else {
                throw BoundaryFailure.timedOut(
                    "A blackholed socket during mounted restoration started no attempt"
                )
            }
            XCTAssertTrue(projection.restoring, "The attempt must not wait for restoration to end")
            NSLog("c-1: the second outage was attempted while restoration was still stalled")
            projection.releaseRestore()
            try await Self.control("pass", port: port, token: proxyToken)
            guard let secondAdmission = lifecycle.generationAdmission,
                  await lifecycle.waitForConnected(
                    until: ContinuousClock().now + .seconds(60),
                    admission: secondAdmission
                  ) else {
                throw BoundaryFailure.timedOut("The lifecycle did not reconnect after the second blackhole")
            }
            let resolved = await appLog.snapshot().filter {
                $0.event == "connection.episode" && $0.message.contains("endedBy=connected")
            }
            XCTAssertGreaterThanOrEqual(resolved.count, 1, "Each outage resolves in one episode record")
            let finalStallCount = await Self.recordCount(in: appLog, event: "reconnect.stalled")
            XCTAssertEqual(finalStallCount, 0, "No attempt gap may be reported as a stall")
            let records = await appLog.snapshot().filter {
                $0.event == "gateway.attempt" || $0.event == "connection.episode"
                    || $0.event == "reconnect.stalled"
            }
            await lifecycle.teardown()
            await client.close()
            return Array(records.dropFirst(attemptsBeforeBlackhole))
        } catch {
            await lifecycle.teardown()
            await client.close()
            throw error
        }
    }

    /// The phone-observed start of each attempt, in milliseconds since the first
    /// one, so a cadence assertion compares offsets rather than timestamps.
    private static func attemptStarts(in appLog: AppLog, droppingFirst count: Int) async -> [Int] {
        let attempts = await appLog.snapshot().filter { $0.event == "gateway.attempt" }
        let dates = attempts.dropFirst(count).compactMap { GatewayTimestamp.parse($0.timestamp) }
        guard let first = dates.first else { return [] }
        return dates.map { Int($0.timeIntervalSince(first) * 1_000) }
    }

    private static func largestGap(_ startsMs: [Int]) -> Int? {
        guard startsMs.count > 1 else { return nil }
        return zip(startsMs, startsMs.dropFirst()).map { $1 - $0 }.max()
    }

    /// The wall-clock instant of one `connection.episode` field, parsed so the
    /// assertion compares instants rather than ISO text.
    private static func episodeDate(_ key: String, in message: String) -> Date? {
        guard let range = message.range(of: "\(key)=") else { return nil }
        let value = message[range.upperBound...].prefix { !$0.isWhitespace }
        return GatewayTimestamp.parse(String(value))
    }

    /// The comma-separated `causes` of one `connection.episode` record, so an
    /// assertion can name the loss that opened it.
    private static func episodeCauses(in message: String) -> [String]? {
        guard let range = message.range(of: "causes=") else { return nil }
        let value = message[range.upperBound...].prefix { !$0.isWhitespace }
        return value.split(separator: ",").map(String.init)
    }

    /// The instant and code the phone observed for a transport loss, for the
    /// assertions that the episode is dated at that loss and names it first.
    private actor LossInstant {
        private var value: Date?
        private var code: String?

        var instant: Date? { value }
        var lossCode: String? { code }

        func record(code: String) {
            if value == nil {
                value = Date()
                self.code = code
            }
        }
    }

    /// A fault-proxy blackhole with the app foregrounded, then a restore. The
    /// export must explain the outage: one `gateway.attempt` record per attempt
    /// of the outage (including the one that recovered) and one
    /// `connection.episode` that resolved it, with the gaps between the
    /// attempts. Returns the outage's own records so the caller can attach them
    /// for inspection.
    @MainActor
    private static func exerciseBlackholedReconnect(
        profile: GatewayProfile,
        token: String,
        port: Int,
        proxyToken: String
    ) async throws -> [AppLogRecord] {
        let memoryTokens = MemoryGatewayTokenStore()
        let profiles = GatewayProfileStore(metadata: MemoryProfileMetadataStore(), tokens: memoryTokens)
        try profiles.save(profile, token: token)
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "o-4-blackhole-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let client = GatewayClient()
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { try? memoryTokens.read(profileID: $0.id) },
            appLog: appLog
        )
        do {
            lifecycle.notePathHint(satisfied: true)
            await lifecycle.start()
            guard lifecycle.connectionState == .connected else {
                throw BoundaryFailure.invalidFixture("The lifecycle did not connect before the blackhole")
            }
            guard try await Self.waitForAttemptCount(1, in: appLog, deadline: .seconds(15)) else {
                throw BoundaryFailure.invalidFixture("The initial attempt was not recorded")
            }
            // The connect before the blackhole is also a `gateway.attempt`; only
            // what is written after this point belongs to the outage.
            let attemptsBeforeBlackhole = await Self.recordCount(in: appLog, event: "gateway.attempt")

            // Retire the live socket beneath a blackholed route, so recovery
            // has to attempt the Gateway while nothing gets through.
            try await Self.control("blackhole", port: port, token: proxyToken)
            lifecycle.enteredBackground()
            let activation = lifecycle.becameActive()
            guard try await Self.waitForAttemptCount(
                attemptsBeforeBlackhole + 1, in: appLog, deadline: .seconds(60)
            ) else {
                throw BoundaryFailure.timedOut("No reconnect attempt was recorded during the blackhole")
            }
            try await Self.control("pass", port: port, token: proxyToken)
            await activation?.value
            guard let admission = lifecycle.generationAdmission,
                  await lifecycle.waitForConnected(
                    until: ContinuousClock().now + .seconds(60),
                    admission: admission
                  ) else {
                throw BoundaryFailure.timedOut("The lifecycle did not reconnect after the blackhole")
            }

            // The scene retirement parked recovery and ended the episode the loss
            // had opened, so this outage's attempts belong to the episode that
            // ended `connected`.
            let records = try await Self.waitForEpisode(
                in: appLog, deadline: ContinuousClock().now + .seconds(20)
            )
            let attempts = Array(
                records.filter { $0.event == "gateway.attempt" }
                    .dropFirst(attemptsBeforeBlackhole)
            )
            let episodes = records.filter { $0.event == "connection.episode" }
            XCTAssertGreaterThanOrEqual(attempts.count, 2, "Every attempt of the outage must be on the timeline")
            XCTAssertEqual(attempts.filter { $0.outcome == "success" }.count, 1)
            XCTAssertTrue(attempts.contains { $0.message.contains("stageReached=connected") })
            XCTAssertTrue(attempts.contains { $0.outcome == "failure" && $0.message.contains("stageReached=") })
            let resolved = episodes.filter { $0.message.contains("endedBy=connected") }
            XCTAssertEqual(resolved.count, 1, "One outage resolves in one episode record")
            let episode = try XCTUnwrap(resolved.first)
            XCTAssertTrue(episode.message.contains("attempts=\(attempts.count)"))
            // A blackholed attempt lasts a whole transport deadline, and a gap
            // between attempt starts contains it, so the gap cannot be smaller.
            let longestBlackholedAttemptMs = attempts
                .filter { $0.outcome == "failure" }
                .compactMap(\.durationMs)
                .max() ?? 0
            XCTAssertGreaterThan(longestBlackholedAttemptMs, 0, "The blackholed attempt must report its duration")
            let maximumGapMs = try XCTUnwrap(
                Self.integerField("maxGapBetweenAttemptsMs", in: episode.message),
                "The episode must report its largest gap"
            )
            XCTAssertGreaterThanOrEqual(maximumGapMs, longestBlackholedAttemptMs)
            // Bind the records before teardown: a live client with a standard
            // reconnect loop must not be left inside the test process.
            let outage = records
            await lifecycle.teardown()
            await client.close()
            return outage
        } catch {
            await lifecycle.teardown()
            await client.close()
            throw error
        }
    }

    private static func recordCount(in appLog: AppLog, event: String) async -> Int {
        await appLog.snapshot().filter { $0.event == event }.count
    }

    private static func waitForAttemptCount(
        _ count: Int, in appLog: AppLog, deadline: Duration
    ) async throws -> Bool {
        let until = ContinuousClock().now + deadline
        while ContinuousClock().now < until {
            if await recordCount(in: appLog, event: "gateway.attempt") >= count { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Waits for the episode a restored blackhole produces, then returns the
    /// outage's attempt and episode records.
    private static func waitForEpisode(
        in appLog: AppLog, deadline: ContinuousClock.Instant
    ) async throws -> [AppLogRecord] {
        while ContinuousClock().now < deadline {
            let records = await appLog.snapshot().filter {
                $0.event == "gateway.attempt" || $0.event == "connection.episode"
            }
            if records.contains(where: { $0.event == "connection.episode" }) { return records }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BoundaryFailure.timedOut("No connection.episode record was written")
    }

    /// The integer value of one `key=value` field in a record message, so an
    /// assertion can compare the number rather than the field's presence.
    private static func integerField(_ key: String, in message: String) -> Int? {
        guard let range = message.range(of: "\(key)=") else { return nil }
        return Int(message[range.upperBound...].prefix { $0.isNumber })
    }

    @MainActor
    private static func exerciseForegroundReconnect(
        profile: GatewayProfile,
        token: String,
        port: Int,
        proxyToken: String,
        sessionID: String
    ) async throws {
        // The private Gateway restarts with a live canonical session while the
        // app lifecycle is backgrounded. Foreground reconnect must need no Retry.
        let memoryTokens = MemoryGatewayTokenStore()
        let profiles = GatewayProfileStore(metadata: MemoryProfileMetadataStore(), tokens: memoryTokens)
        try profiles.save(profile, token: token)
        let client = GatewayClient()
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { try? memoryTokens.read(profileID: $0.id) }
        )
        do {
            lifecycle.notePathHint(satisfied: true)
            await lifecycle.start()
            guard lifecycle.connectionState == .connected else {
                throw BoundaryFailure.invalidFixture("App lifecycle did not connect to the private Gateway")
            }
            let beforeRestart: GatewaySessionOpenResponse = try await client.request(
                "session.open", SessionParams(sessionId: sessionID)
            )
            let beforeSync: SyncResponse = try await client.request(
                "session.sync", SyncParams(sessionId: sessionID, syncToken: beforeRestart.syncToken)
            )
            guard beforeSync.synchronized else { throw BoundaryFailure.invalidFixture("Could not synchronize the pre-restart session") }
            let promptCountBeforeRestart = Self.userMessageCount(in: beforeRestart.session)
            lifecycle.enteredBackground()

            let url = URL(string: "http://127.0.0.1:\(port)/_fixture/control")!
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue(proxyToken, forHTTPHeaderField: "x-tron-fixture-token")
            request.httpBody = try JSONEncoder.gateway.encode(["mode": JSONValue.string("restart-gateway")])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw BoundaryFailure.invalidFixture("Owned Gateway restart was not acknowledged")
            }

            // This wait proves the lifecycle coordinator reconnected automatically;
            // the following manual open is only an independent canonical-state read.
            await lifecycle.becameActive()?.value
            guard let admission = lifecycle.generationAdmission,
                  await lifecycle.waitForConnected(
                    until: ContinuousClock().now + .seconds(30),
                    admission: admission
                  ) else {
                throw BoundaryFailure.timedOut("Foreground lifecycle did not reconnect without Retry")
            }
            let restored: GatewaySessionOpenResponse = try await client.request(
                "session.open", SessionParams(sessionId: sessionID)
            )
            let restoredSync: SyncResponse = try await client.request(
                "session.sync", SyncParams(sessionId: sessionID, syncToken: restored.syncToken)
            )
            guard restoredSync.synchronized else {
                throw BoundaryFailure.invalidFixture("Foreground reconnect did not synchronize the preserved session")
            }
            // `session.open` is the authoritative transcript snapshot RPC; the
            // `session.snapshot` name is an event topic, not a request method.
            XCTAssertEqual(restored.session.sessionId, sessionID)
            XCTAssertTrue(Self.text(in: restored.session).contains("Tool response complete after all three tools."))
            XCTAssertEqual(Self.userMessageCount(in: restored.session), promptCountBeforeRestart)
            let catalog: SessionListResponse = try await client.request(
                "session.list", SessionListParams(cursor: nil, limit: 500, scope: "user")
            )
            let catalogSession = catalog.sessions.filter { $0.id == sessionID }
            XCTAssertEqual(catalogSession.count, 1)
            XCTAssertEqual(catalogSession.first?.phase, .idle)
            let restoredClose: CloseResponse = try await client.request(
                "session.close", CloseParams(sessionId: sessionID, subscriptionToken: restored.subscriptionToken)
            )
            guard restoredClose.closed else { throw BoundaryFailure.invalidFixture("Could not retire the restored subscription") }
        } catch {
            await lifecycle.teardown()
            await client.close()
            throw error
        }
        await lifecycle.teardown()
        await client.close()
    }

    private static func userMessageCount(in snapshot: SessionSnapshot) -> Int {
        snapshot.transcript.reduce(into: 0) { count, item in
            guard case .message(let message) = item, message.role == .user else { return }
            count += 1
        }
    }

    private func makeClient(networkPath: (@Sendable () -> String?)? = nil) -> GatewayClient {
        let client = networkPath.map { path in GatewayClient(networkPath: path) } ?? GatewayClient()
        addTeardownBlock { await client.close() }
        return client
    }

    private func control(_ mode: String, port: Int, token: String, commandID: String? = nil, status: Int? = nil, closeCode: Int? = nil, bytes: Int? = nil, httpBlackhole: Bool = false, rateBytesPerSecond: Int? = nil, latencyMilliseconds: Int? = nil, maximumQueuedBytes: Int? = nil) async throws {
        try await Self.control(
            mode, port: port, token: token, commandID: commandID, status: status,
            closeCode: closeCode, bytes: bytes, httpBlackhole: httpBlackhole,
            rateBytesPerSecond: rateBytesPerSecond, latencyMilliseconds: latencyMilliseconds,
            maximumQueuedBytes: maximumQueuedBytes
        )
    }

    /// The isolated fault proxy's control plane. It is static so the blackhole
    /// helper can drive the proxy without carrying the test case into a
    /// main-actor function.
    private static func control(_ mode: String, port: Int, token: String, commandID: String? = nil, status: Int? = nil, closeCode: Int? = nil, bytes: Int? = nil, httpBlackhole: Bool = false, rateBytesPerSecond: Int? = nil, latencyMilliseconds: Int? = nil, maximumQueuedBytes: Int? = nil) async throws {
        _ = try await Self.controlValue(
            mode, port: port, token: token, commandID: commandID, status: status,
            closeCode: closeCode, bytes: bytes, httpBlackhole: httpBlackhole,
            rateBytesPerSecond: rateBytesPerSecond, latencyMilliseconds: latencyMilliseconds,
            maximumQueuedBytes: maximumQueuedBytes
        )
    }

    private func controlValue(_ mode: String, port: Int, token: String) async throws -> JSONValue {
        try await Self.controlValue(mode, port: port, token: token)
    }

    private static func controlValue(_ mode: String, port: Int, token: String, commandID: String? = nil, status: Int? = nil, closeCode: Int? = nil, bytes: Int? = nil, httpBlackhole: Bool = false, rateBytesPerSecond: Int? = nil, latencyMilliseconds: Int? = nil, maximumQueuedBytes: Int? = nil) async throws -> JSONValue {
        let url = URL(string: "http://127.0.0.1:\(port)/_fixture/control")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-tron-fixture-token")
        var values: [String: JSONValue] = ["mode": .string(mode)]
        if let commandID { values["commandId"] = .string(commandID) }
        if let status { values["status"] = .number(Double(status)) }
        if let closeCode { values["code"] = .number(Double(closeCode)) }
        if let bytes { values["bytes"] = .number(Double(bytes)) }
        if let rateBytesPerSecond { values["rateBytesPerSecond"] = .number(Double(rateBytesPerSecond)) }
        if let latencyMilliseconds { values["latencyMilliseconds"] = .number(Double(latencyMilliseconds)) }
        if let maximumQueuedBytes { values["maximumQueuedBytes"] = .number(Double(maximumQueuedBytes)) }
        if httpBlackhole { values["http"] = .bool(true) }
        request.httpBody = try JSONEncoder.gateway.encode(values)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoundaryFailure.invalidFixture("Isolated fault control did not acknowledge \(mode)")
        }
        return try JSONDecoder.gateway.decode(JSONValue.self, from: data)
    }

    private func waitForDisconnectReason(client: GatewayClient) async throws -> String? {
        let events = client.events
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for await delivery in events where delivery.event.topic == "transport.disconnected" {
                    return delivery.event.payload.objectValue?["reason"]?.stringValue
                }
                throw BoundaryFailure.invalidFixture("Missing oversized-frame disconnect")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw BoundaryFailure.timedOut("Oversized frame did not retire the connection")
            }
            let reason = try await group.next() ?? nil
            group.cancelAll()
            return reason
        }
    }

    private func waitForDisconnect(client: GatewayClient) async throws {
        let events = client.events
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await delivery in events {
                    if delivery.event.topic == "transport.disconnected" { return }
                }
                throw BoundaryFailure.invalidFixture("Missing remote disconnect")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw BoundaryFailure.timedOut("Remote close was not delivered")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func waitForStreamingText(
        client: GatewayClient,
        sessionID: String,
        containing expected: String
    ) async throws {
        let events = client.events
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                while let delivery = await iterator.next() {
                    guard delivery.event.sessionId == sessionID,
                          case .sessionEvent(let prepared) = delivery.event.preparation,
                          case .progress(let item) = prepared.data else { continue }
                    if Self.text(in: item).contains(expected) { return }
                }
                throw BoundaryFailure.invalidFixture("Gateway event stream ended before Pi streamed output")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw BoundaryFailure.timedOut("Timed out waiting for decoded Pi streaming output")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func waitForInteraction(
        client: GatewayClient,
        sessionID: String,
        excluding answered: Set<String>,
        description: String
    ) async throws -> (ExtensionInteraction, String) {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(25)
        repeat {
            let opened = try await synchronizedOpen(client: client, sessionID: sessionID)
            if let interaction = opened.session.extensionPresentation.pendingInteractions.first(where: {
                !answered.contains($0.id)
            }) {
                return (interaction, opened.subscriptionToken)
            }
            try await closeSubscription(
                client: client,
                sessionID: sessionID,
                token: opened.subscriptionToken
            )
            try await Task.sleep(for: .milliseconds(150))
        } while clock.now < deadline
        throw BoundaryFailure.timedOut("Timed out waiting for \(description)")
    }

    private func waitForSnapshot(
        client: GatewayClient,
        sessionID: String,
        description: String,
        predicate: (SessionSnapshot) -> Bool
    ) async throws -> SessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(25)
        repeat {
            let snapshot = try await synchronizedSnapshot(client: client, sessionID: sessionID)
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(150))
        } while clock.now < deadline
        throw BoundaryFailure.timedOut("Timed out waiting for \(description)")
    }

    private func synchronizedSnapshot(client: GatewayClient, sessionID: String) async throws -> SessionSnapshot {
        let opened = try await synchronizedOpen(client: client, sessionID: sessionID)
        try await closeSubscription(client: client, sessionID: sessionID, token: opened.subscriptionToken)
        return opened.session
    }

    /// The phone's hello key and the real Gateway's `connection.opened` record
    /// name the same attempt, joined by the connection ID the hello returned.
    private func assertCorrelationKey(client: GatewayClient) async throws {
        let diagnostics = await client.diagnostics()
        let handshake = try XCTUnwrap(diagnostics.first { $0.stage == .helloReceive && $0.outcome == .success })
        let gatewayConnectionID = try XCTUnwrap(handshake.gatewayConnectionID)
        let epoch = String(try XCTUnwrap(handshake.connectionID))
        let logs = try await client.requestValue(
            "system.logs", JSONValue.object(["limit": .number(1_000)]), timeout: .seconds(15)
        )
        let opened = try XCTUnwrap(logs.objectValue?["records"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["event"] == .string("connection.opened") && $0["connectionId"] == .string(gatewayConnectionID)
        }, "the Gateway must record the connection its hello named")
        XCTAssertEqual(opened["peerClientId"], .string(client.diagnosticOwnerID))
        XCTAssertEqual(opened["peerAttemptId"], .string("initial"))
        XCTAssertEqual(opened["peerEpoch"], .string(epoch))
        let attachment = XCTAttachment(string: [
            "phone clientId=\(client.diagnosticOwnerID) attemptId=\(handshake.attemptID ?? "initial") epoch=\(epoch) gatewayConnectionId=\(gatewayConnectionID)",
            "gateway connection.opened connectionId=\(opened["connectionId"]?.stringValue ?? "-") peerClientId=\(opened["peerClientId"]?.stringValue ?? "-") peerAttemptId=\(opened["peerAttemptId"]?.stringValue ?? "-") peerEpoch=\(opened["peerEpoch"]?.stringValue ?? "-")",
        ].joined(separator: "\n"))
        attachment.name = "connection-correlation-key"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Agent Instructions sheet decodes the real Gateway projection: the
    /// workspace AGENTS.md is attributed to its file, Pi's own tools to Pi, and
    /// the per-turn Tron context closes the exact prompt text.
    private func assertAgentInstructions(client: GatewayClient, sessionID: String, workspace: String) async throws {
        let context = try await client.requestValue("session.context", SessionParams(sessionId: sessionID), timeout: .seconds(15))
        let instructions = try XCTUnwrap(AgentInstructionsProjection(context: context), "session.context must carry instructions")
        let outline = instructions.sections.map { section in
            "\(section.id) timing=\(section.perTurn ? "turn" : "session") chars=\(section.text.count) entries="
                + section.entries.map { "\($0.name ?? "-")@\($0.source.kind)" }.joined(separator: ",")
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: outline)
        attachment.name = "agent-instructions-outline"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(instructions.sections.first?.id, "preamble")
        let tron = try XCTUnwrap(instructions.sections.last)
        XCTAssertEqual(tron.id, "tron")
        XCTAssertTrue(tron.perTurn)
        XCTAssertTrue(tron.text.contains(workspace))
        XCTAssertTrue(instructions.text.hasSuffix("\n\n" + tron.text))
        let project = try XCTUnwrap(instructions.sections.first { $0.id == "project_context" })
        XCTAssertEqual(project.entries.map(\.path), ["\(workspace)/AGENTS.md"])
        XCTAssertEqual(project.entries.first?.text, "# E2E Project Rules\n\nKeep the boundary fixture honest.\n")
        XCTAssertEqual(project.entries.first?.source.kind, "file")
        let tools = try XCTUnwrap(instructions.sections.first { $0.id == "tools" })
        XCTAssertEqual(tools.entries.first { $0.name == "bash" }?.source.kind, "pi")
        XCTAssertEqual(tools.entries.first { $0.name == "ask_user" }?.source.name, "tron-ask-user")
    }

    private func synchronizedOpen(
        client: GatewayClient,
        sessionID: String
    ) async throws -> GatewaySessionOpenResponse {
        let opened: GatewaySessionOpenResponse = try await client.request(
            "session.open",
            SessionParams(sessionId: sessionID),
            timeout: .seconds(15)
        )
        guard opened.session.sessionId == sessionID else {
            throw BoundaryFailure.invalidFixture("Gateway opened a different session")
        }
        let synchronized: SyncResponse = try await client.request(
            "session.sync",
            SyncParams(sessionId: sessionID, syncToken: opened.syncToken),
            timeout: .seconds(15)
        )
        guard synchronized.synchronized else {
            throw BoundaryFailure.invalidFixture("Gateway did not acknowledge the synchronized snapshot")
        }
        return opened
    }

    private func closeSubscription(
        client: GatewayClient,
        sessionID: String,
        token: String
    ) async throws {
        let closed: CloseResponse = try await client.request(
            "session.close",
            CloseParams(sessionId: sessionID, subscriptionToken: token),
            timeout: .seconds(15)
        )
        guard closed.closed else {
            throw BoundaryFailure.invalidFixture("Gateway did not close the snapshot subscription")
        }
    }

    private static func text(in snapshot: SessionSnapshot) -> String {
        snapshot.transcript.map(text(in:)).joined(separator: "\n")
    }

    private static func text(in item: TranscriptItem) -> String {
        guard case .message(let message) = item else { return "" }
        return message.content.compactMap(\.text).joined(separator: "\n")
    }
}

/// The presentation owner of a connected socket whose mounted restoration
/// stalls until the leg releases it: the shape of slow projection work that a
/// reconnect loop used to await. The initial connect's own restoration
/// completes, so the leg starts from an established lifecycle.
@MainActor
private final class StallingRestoreProjection: GatewayLifecycleProjectionDelegate {
    private(set) var restoreCount = 0
    private(set) var restoring = false
    private var stallArmed = false
    private var restoreContinuation: CheckedContinuation<Void, Never>?

    /// Arms the stall for the next restoration, never for the initial connect's.
    /// The arm is one-shot: a later restoration (the reconnect that ends the
    /// second outage) must settle, or the lifecycle teardown waits on a stall
    /// nothing releases.
    func stallNextRestore() { stallArmed = true }

    func waitUntilRestoring(deadline: Duration) async -> Bool {
        let until = ContinuousClock().now + deadline
        while ContinuousClock().now < until {
            if restoring { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return restoring
    }

    func releaseRestore() {
        restoring = false
        let continuation = restoreContinuation
        restoreContinuation = nil
        continuation?.resume()
    }

    func lifecycleLoadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async {}
    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleBeginReconciliationAggregate(admission: GatewayLifecycleCoordinator.Admission) {}
    func lifecycleCompleteReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission,
        succeeded: Bool
    ) {}
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRestoreMountedPresentation(
        admission: GatewayLifecycleCoordinator.Admission
    ) async -> Bool {
        restoreCount += 1
        guard stallArmed else { return true }
        stallArmed = false
        restoring = true
        await withCheckedContinuation { restoreContinuation = $0 }
        return true
    }
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) {}
}
