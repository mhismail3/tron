import Foundation
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
    private struct ModelParams: Encodable { let sessionId: String; let provider: String; let modelId: String; let commandId: String }
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
            let hello = try JSONEncoder.gateway.encode(["type": JSONValue.string("hello"), "protocolVersion": .number(5)])
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
            let socket = GatewaySocketFactory.urlSession.makeConnection(probeRequest)
            let hello = try JSONEncoder.gateway.encode(["type": JSONValue.string("hello"), "protocolVersion": .number(5)])
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
            sessionId: created.sessionId, provider: "tron-e2e", modelId: "e2e-model", commandId: UUID().uuidString))
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
        try await exerciseBlackholedReconnect(
            profile: profile,
            token: token,
            port: port,
            proxyToken: proxyToken
        )
    }

    /// A fault-proxy blackhole with the app foregrounded, then a restore. The
    /// export must explain the outage: one `gateway.attempt` record per attempt
    /// (including the one that recovered) and exactly one `connection.episode`
    /// with the gap between them. The records are attached for inspection.
    @MainActor
    private func exerciseBlackholedReconnect(
        profile: GatewayProfile,
        token: String,
        port: Int,
        proxyToken: String
    ) async throws {
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

            // Retire the live socket beneath a blackholed route, so recovery
            // has to attempt the Gateway while nothing gets through.
            try await Self.setProxyMode("blackhole", port: port, token: proxyToken)
            lifecycle.enteredBackground()
            let activation = lifecycle.becameActive()
            guard try await Self.waitForAttemptCount(2, in: appLog, deadline: .seconds(60)) else {
                throw BoundaryFailure.timedOut("No reconnect attempt was recorded during the blackhole")
            }
            try await Self.setProxyMode("pass", port: port, token: proxyToken)
            await activation?.value
            guard let admission = lifecycle.generationAdmission,
                  await lifecycle.waitForConnected(
                    until: ContinuousClock().now + .seconds(60),
                    admission: admission
                  ) else {
                throw BoundaryFailure.timedOut("The lifecycle did not reconnect after the blackhole")
            }

            let records = try await Self.waitForEpisode(
                in: appLog, deadline: ContinuousClock().now + .seconds(20)
            )
            let attempts = records.filter { $0.event == "gateway.attempt" }
            let episodes = records.filter { $0.event == "connection.episode" }
            XCTAssertGreaterThanOrEqual(attempts.count, 2, "Every attempt must be on the timeline")
            XCTAssertEqual(attempts.filter { $0.outcome == "success" }.count, 1)
            XCTAssertTrue(attempts.contains { $0.message.contains("stageReached=connected") })
            XCTAssertTrue(attempts.contains { $0.outcome == "failure" && $0.message.contains("stageReached=") })
            XCTAssertEqual(episodes.count, 1, "One outage is one episode record")
            XCTAssertTrue(episodes[0].message.contains("endedBy=connected"))
            XCTAssertTrue(episodes[0].message.contains("attempts=\(attempts.count)"))
            XCTAssertTrue(episodes[0].message.contains("maxGapBetweenAttemptsMs="))
            let attachment = XCTAttachment(string: records.map { record in
                "\(record.timestamp) \(record.level) \(record.event) durationMs=\(record.durationMs ?? -1) outcome=\(record.outcome ?? "-") \(record.message)"
            }.joined(separator: "\n"))
            attachment.name = "phone-connection-records"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            await lifecycle.teardown()
            await client.close()
            throw error
        }
        await lifecycle.teardown()
        await client.close()
    }

    private static func setProxyMode(_ mode: String, port: Int, token: String) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/_fixture/control")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-tron-fixture-token")
        request.httpBody = try JSONEncoder.gateway.encode(["mode": JSONValue.string(mode)])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoundaryFailure.invalidFixture("Isolated fault control did not acknowledge \(mode)")
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

    private func makeClient() -> GatewayClient {
        let client = GatewayClient()
        addTeardownBlock { await client.close() }
        return client
    }

    private func control(_ mode: String, port: Int, token: String, commandID: String? = nil, status: Int? = nil, closeCode: Int? = nil, bytes: Int? = nil) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/_fixture/control")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-tron-fixture-token")
        var values: [String: JSONValue] = ["mode": .string(mode)]
        if let commandID { values["commandId"] = .string(commandID) }
        if let status { values["status"] = .number(Double(status)) }
        if let closeCode { values["code"] = .number(Double(closeCode)) }
        if let bytes { values["bytes"] = .number(Double(bytes)) }
        request.httpBody = try JSONEncoder.gateway.encode(values)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BoundaryFailure.invalidFixture("Isolated fault control did not acknowledge \(mode)")
        }
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
