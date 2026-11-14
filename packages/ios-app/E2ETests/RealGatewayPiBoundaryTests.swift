import Foundation
@testable import TronMobileCore
import XCTest
@testable import TronMobile

private func connectForBoundary(_ client: GatewayClient, profile: GatewayProfile, token: String) async throws -> GatewayInfo {
    let connection = try await client.connectForLifecycle(profile: profile, token: token)
    try await client.activateEvents(connectionID: connection.id)
    return connection.info
}

final class RealGatewayPiBoundaryTests: XCTestCase {
    private struct SessionIDResponse: Decodable { let sessionId: String }
    private struct OperationResponse: Decodable { let operationId: String }
    private struct MutationResponse: Decodable { let answered: Bool }
    private struct SyncResponse: Decodable { let synchronized: Bool }
    private struct CloseResponse: Decodable { let closed: Bool }
    private struct ReceiptParams: Encodable { let commandId: String; let method: String }
    private struct ReceiptResponse: Decodable { let status: String; let result: JSONValue? }
    private struct SettingsChangeResponse: Decodable { let status: String }

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

    @MainActor
    private final class CatalogNotices: ProviderAuthCoordinatorDelegate {
        var errors: [String] = []
        func providerAuthCoordinatorSurface(_ error: Error) { errors.append(error.localizedDescription) }
        func providerAuthCoordinatorSetCompletionError(_ message: String?) {
            if let message { errors.append(message) }
        }
    }

    @MainActor
    private static func assertRegularSessionModelCatalog(client: GatewayClient, sessionID: String, port: Int, proxyToken: String) async throws -> String {
        let profiles = GatewayProfileStore(metadata: MemoryProfileMetadataStore(), tokens: MemoryGatewayTokenStore())
        let lifecycle = GatewayLifecycleCoordinator(
            client: client, profiles: profiles, clock: .continuous, reconnectDelayPolicy: .standard,
            uuidSource: .random, pairer: GatewayPairer(), pairingCommit: { _, _ in }, profileTokenLookup: { _ in nil }
        )
        let coordinator = ProviderAuthCoordinator(client: client, mutationExecutor: ConfirmedMutationExecutor(
            client: client, lifecycle: lifecycle, clock: .continuous, performanceSignposts: SystemPerformanceSignposts.shared
        ), uuidSource: .random)
        let notices = CatalogNotices()
        coordinator.delegate = notices
        let target = ProviderCatalogTarget.session(id: sessionID)
        let loaded = await coordinator.refreshCatalog(target: target)
        XCTAssertTrue(loaded, "Regular-session catalog must load with model queues configured: \(notices.errors)")
        XCTAssertTrue(notices.errors.isEmpty, "The production toast path must remain silent: \(notices.errors)")
        let models = try XCTUnwrap(coordinator.catalog(for: target)?.models)
        let router = try XCTUnwrap(models.first { $0.provider == "tron" && $0.id == "subagent" })
        XCTAssertEqual(router.virtual, true)
        XCTAssertEqual(router.contextWindow, 0, "Unknown routed capacity must not be fabricated")
        XCTAssertEqual(router.maxTokens, 0)
        XCTAssertTrue(models.contains { $0.provider == "tron-e2e" && $0.id == "e2e-model" && $0.available },
                      "A virtual router must not discard the usable physical catalog")
        for (mode, field) in [("invalid-physical-model-limit", "contextWindow"), ("invalid-virtual-model-limit", "maxTokens")] {
            try await control(mode, port: port, token: proxyToken)
            let accepted = await coordinator.refreshCatalog(target: target)
            try await control("pass", port: port, token: proxyToken)
            XCTAssertFalse(accepted)
            XCTAssertEqual(notices.errors.count, 1, "A genuine invalid entry must surface once")
            notices.errors.removeAll()
            XCTAssertEqual(coordinator.catalog(for: target)?.models, models, "Rejected refresh keeps the last usable catalog")
            let records = await AppLog.shared.snapshot()
            XCTAssertTrue(records.contains { $0.event == "model.catalog.rejected"
                && $0.message.contains(".\(field) reason=invalid_token_limit") }, "Log must identify the exact failed field")
            let recovered = await coordinator.refreshCatalog(target: target)
            XCTAssertTrue(recovered)
            XCTAssertTrue(notices.errors.isEmpty)
        }
        return "tron/subagent virtual=\(router.virtual == true) contextWindow=\(router.contextWindow) maxTokens=\(router.maxTokens); catalog loaded; surfaced errors=0; physical zero and virtual negative rejected with field diagnostics; refresh recovered"
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
                _ = try await connectForBoundary(rejectedClient, profile: profile, token: token)
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
        let connecting = Task { try await connectForBoundary(initialClient, profile: profile, token: token) }
        defer { connecting.cancel() }
        try await control("await-intercepted", port: port, token: proxyToken)
        try await control("pass", port: port, token: proxyToken)
        let firstInfo = try await connecting.value
        XCTAssertEqual(firstInfo.piVersion, expectedPiVersion, "The iOS boundary must exercise the selected Pi runtime")
        try await assertCorrelationKey(client: initialClient)

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
            let rawSession = URLSession(configuration: .ephemeral)
            defer { rawSession.invalidateAndCancel() }
            let raw = rawSession.webSocketTask(with: probeRequest)
            raw.resume()
            let hello = try JSONEncoder.gateway.encode(["type": JSONValue.string("hello"), "protocolVersion": .number(8)])
            try await raw.send(.data(hello))
            _ = try await raw.receive()
            try await control("close", port: port, token: proxyToken, closeCode: 1013)
            do { _ = try await raw.receive() } catch { }
            platformCloseCode = raw.closeCode.rawValue
        }
        do {
            let socket = GatewaySocketFactory.urlSession.makeConnection(probeRequest, nil)
            let hello = try JSONEncoder.gateway.encode(["type": JSONValue.string("hello"), "protocolVersion": .number(8)])
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
            let oversizedClient = makeClient()
            _ = try await connectForBoundary(oversizedClient, profile: profile, token: token)
            try await control("inject-frame", port: port, token: proxyToken, bytes: GatewayFramePolicy.maximumInboundBytes + 1)
            let reason = try await waitForDisconnectReason(client: oversizedClient)
            XCTAssertEqual(reason, "frame_too_large", "The simulator app must negotiate compression and reject the inflated frame")
            await oversizedClient.close()
        }
        let remotelyClosedClient = makeClient()
        _ = try await connectForBoundary(remotelyClosedClient, profile: profile, token: token)
        try await control("close", port: port, token: proxyToken, closeCode: 1013)
        try await waitForDisconnect(client: remotelyClosedClient)
        let remoteDiagnostics = await remotelyClosedClient.diagnostics()
        XCTAssertTrue(remoteDiagnostics.contains { $0.closeCode == (platformCloseCode == 0 ? nil : platformCloseCode) && $0.httpStatusCode == 101 },
                      "Remote close must retain the independent Foundation status \(platformCloseCode)")
        await remotelyClosedClient.close()
        let firstClient = makeClient()
        _ = try await connectForBoundary(firstClient, profile: profile, token: token)

        let queues: SettingsChangeResponse = try await firstClient.request("settings.change", JSONValue.object([
            "commandId": .string(UUID().uuidString),
            "target": .object(["kind": .string("home")]),
            "changes": .array(["worker", "subagent", "background"].map { role in
                .object(["key": .string("model.queue[role=\(role)]"), "layer": .string("session"),
                         "op": .string("set"), "value": .array([.string("tron-e2e/e2e-model")])])
            }),
        ]))
        XCTAssertEqual(queues.status, "applied")
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
        let catalogEvidence = try await Self.assertRegularSessionModelCatalog(client: firstClient, sessionID: created.sessionId, port: port, proxyToken: proxyToken)
        let catalogAttachment = XCTAttachment(string: catalogEvidence)
        catalogAttachment.name = "1215-regular-session-model-catalog"
        catalogAttachment.lifetime = .keepAlways
        add(catalogAttachment)
        let selected: SettingsChangeResponse = try await firstClient.request("settings.change", JSONValue.object([
            "commandId": .string(UUID().uuidString),
            "target": .object(["kind": .string("session"), "sessionId": .string(created.sessionId)]),
            "fence": .object(["runtimeGeneration": .string(opened.session.runtimeGeneration),
                              "model": try opened.session.model.map { try JSONValue.encode($0) } ?? .null]),
            "changes": .array([.object(["key": .string("model.ref[role=chat]"), "layer": .string("session"), "op": .string("set"),
                                        "value": .object(["provider": .string("tron-e2e"), "id": .string("e2e-model")])])]),
        ]))
        XCTAssertEqual(selected.status, "applied")
        let compaction: SettingsChangeResponse = try await firstClient.request("settings.change", JSONValue.object([
            "commandId": .string(UUID().uuidString),
            "target": .object(["kind": .string("session"), "sessionId": .string(created.sessionId)]),
            "fence": .object(["runtimeGeneration": .string(opened.session.runtimeGeneration),
                              "model": .object(["provider": .string("tron-e2e"), "id": .string("e2e-model")])]),
            "changes": .array([.object(["key": .string("context.compaction.keepRecentTokens"), "layer": .string("session"), "op": .string("set"),
                                        "value": .number(24_000)])]),
        ]))
        XCTAssertEqual(compaction.status, "applied")
        let configured = try await synchronizedOpen(client: firstClient, sessionID: created.sessionId)
        XCTAssertEqual(configured.session.model?.provider, "tron-e2e")
        XCTAssertEqual(configured.session.model?.id, "e2e-model")
        XCTAssertEqual(configured.session.compactionPolicy?.next.source["keepRecentTokens"], "session")
        XCTAssertEqual(configured.session.compactionPolicy?.next.keepRecentTokens, 24_000)
        XCTAssertTrue(SessionSnapshotTranscriptAdmissionPolicy.admit(configured.session),
                      "a snapshot with a Chat compaction value must be admitted")
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
        _ = try await connectForBoundary(streamingClient, profile: profile, token: token)
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

        await streamingClient.close()

        let reconnectedClient = makeClient()
        let reconnectedInfo = try await connectForBoundary(reconnectedClient, profile: profile, token: token)
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
        _ = try await connectForBoundary(client, profile: profile, token: token)
        let connectedID = await client.activeConnectionID()
        let originalConnectionID = try XCTUnwrap(connectedID)
        let payload = Data(repeating: 0x78, count: 298_013)

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

        try await control("unshape", port: port, token: proxyToken)
        let largeBatch = DeviceLogAppendProbe(
            commandId: UUID().uuidString,
            bootId: "e2e-large-batch-\(UUID().uuidString.prefix(8))",
            firstSequence: 1,
            lines: (1...16).map { index in
                #"{"timestamp":"2026-11-14T00:00:00.000Z","level":"info","event":"e2e.large-batch","source":"app","message":"\#(index) "# + String(repeating: "x", count: 15_000) + #""}"#
            }
        )
        let appended = try await client.requestValue("client.logs.append", largeBatch, timeout: .seconds(15))
        XCTAssertEqual(appended.objectValue?["sequence"]?.intValue, 16)
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
        let onWifi: @Sendable () -> String? = { "wifi,other" }

        try await control("hold-hello", port: port, token: proxyToken)
        let lanClient = makeClient(networkPath: onWifi)
        _ = try await connectForBoundary(lanClient, profile: paired, token: token)
        try await control("pass", port: port, token: proxyToken)
        let lanHandshakes = await successfulHandshakes(of: lanClient)
        XCTAssertEqual(lanHandshakes.count, 1)
        XCTAssertEqual(lanHandshakes.first?.handshake?.transport, "lan")

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

        let blockedLane = try HangingLanLane()
        defer { blockedLane.close() }
        var blocked = paired
        blocked.lanEndpoints = [try XCTUnwrap(GatewayLanEndpoint(host: "127.0.0.1", port: blockedLane.port))]
        let blockedClient = makeClient(networkPath: onWifi)
        let attemptStarted = ContinuousClock().now
        _ = try await connectForBoundary(blockedClient, profile: blocked, token: token)
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
        let blockedLaneLosses = await lanFailures(of: blockedClient)
        XCTAssertTrue(blockedLaneLosses.isEmpty, "A lane the winner retired must not be recorded as a LAN failure")
        await blockedClient.close()

        var mismatched = paired
        mismatched.lanPin = Data(repeating: 0x5a, count: 32).base64EncodedString()
        let mismatchedClient = makeClient(networkPath: onWifi)
        _ = try await connectForBoundary(mismatchedClient, profile: mismatched, token: token)
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

    private func successfulHandshakes(of client: GatewayClient) async -> [GatewayConnectionDiagnostic] {
        await client.diagnostics()
            .filter { $0.outcome == .success && $0.stage == .helloReceive }
            .sorted { $0.sequence < $1.sequence }
    }

    private func lanFailures(of client: GatewayClient) async -> [GatewayConnectionDiagnostic] {
        await client.diagnostics()
            .filter { $0.outcome == .failure && $0.handshake?.transport == "lan" }
            .sorted { $0.sequence < $1.sequence }
    }

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
                return sawBytes
            }
            return false
        }

        func close() { Darwin.close(descriptor) }

        private static func milliseconds(_ duration: Duration) -> Int32 {
            Int32(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
    }

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

            projection.stallNextRestore()

            try await Self.control("blackhole", port: port, token: proxyToken)
            NSLog("c-1: 90 s blackhole starts")
            let blackholeAt = ContinuousClock().now
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

    private static func episodeDate(_ key: String, in message: String) -> Date? {
        guard let range = message.range(of: "\(key)=") else { return nil }
        let value = message[range.upperBound...].prefix { !$0.isWhitespace }
        return GatewayTimestamp.parse(String(value))
    }

    private static func episodeCauses(in message: String) -> [String]? {
        guard let range = message.range(of: "causes=") else { return nil }
        let value = message[range.upperBound...].prefix { !$0.isWhitespace }
        return value.split(separator: ",").map(String.init)
    }

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
            let attemptsBeforeBlackhole = await Self.recordCount(in: appLog, event: "gateway.attempt")

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
            XCTAssertEqual(restored.session.sessionId, sessionID)
            XCTAssertTrue(Self.text(in: restored.session).contains("Tool response complete after all three tools."))
            XCTAssertEqual(Self.userMessageCount(in: restored.session), promptCountBeforeRestart)
            let catalog = try await client.requestValue(
                "session.list", SessionListParams(cursor: nil, limit: 500, scope: "user")
            ).decodeWire(SessionListPage.validated)
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
        addTeardownBlock {
            await Self.attachLivenessRecords(of: client)
            await client.close()
        }
        return client
    }

    private static func attachLivenessRecords(of client: GatewayClient) async {
        let records = await client.diagnostics()
            .filter { $0.stage == .liveness || $0.stage == .transport }
            .sorted { $0.sequence < $1.sequence }
        guard !records.isEmpty else { return }
        let lines: [String] = records.map { record in
            let value = JSONValue.object([
                "clientId": .string(client.diagnosticOwnerID),
                "sequence": .number(Double(record.sequence)),
                "stage": .string(record.stage.rawValue),
                "outcome": .string(record.outcome.rawValue),
                "timestamp": .string(record.timestamp),
                "durationMilliseconds": .number(Double(record.durationMilliseconds)),
                "reason": Self.optionalString(record.reason?.rawValue),
                "connectionID": Self.optionalNumber(record.connectionID),
                "gatewayConnectionID": Self.optionalString(record.gatewayConnectionID),
                "attemptID": Self.optionalString(record.attemptID),
                "lastInboundAgeMilliseconds": Self.optionalNumber(record.lastInboundAgeMilliseconds),
                "lastWriteProgressAgeMilliseconds": Self.optionalNumber(record.lastWriteProgressAgeMilliseconds),
                "platformCode": Self.optionalNumber(record.platformCode),
                "closeCode": Self.optionalNumber(record.closeCode),
                "httpStatusCode": Self.optionalNumber(record.httpStatusCode),
            ])
            return String(decoding: (try? JSONEncoder.gateway.encode(value)) ?? Data(), as: UTF8.self)
        }
        let text = lines.joined(separator: "\n") + "\n"
        await MainActor.run {
            XCTContext.runActivity(named: "phone-liveness-records") { activity in
                let attachment = XCTAttachment(string: text)
                attachment.name = "phone-liveness-records"
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
    }

    private static func optionalNumber(_ value: Int?) -> JSONValue {
        value.map { JSONValue.number(Double($0)) } ?? .null
    }

    private static func optionalString(_ value: String?) -> JSONValue {
        value.map { JSONValue.string($0) } ?? .null
    }

    private func control(_ mode: String, port: Int, token: String, commandID: String? = nil, status: Int? = nil, closeCode: Int? = nil, bytes: Int? = nil, httpBlackhole: Bool = false, rateBytesPerSecond: Int? = nil, latencyMilliseconds: Int? = nil, maximumQueuedBytes: Int? = nil) async throws {
        try await Self.control(
            mode, port: port, token: token, commandID: commandID, status: status,
            closeCode: closeCode, bytes: bytes, httpBlackhole: httpBlackhole,
            rateBytesPerSecond: rateBytesPerSecond, latencyMilliseconds: latencyMilliseconds,
            maximumQueuedBytes: maximumQueuedBytes
        )
    }

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

    @MainActor
    func testPhoneLogMarkerReachesGatewayDeviceFile() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["TRON_E2E_PORT"],
              let port = Int(portText),
              let code = environment["TRON_E2E_CODE"],
              let tronHome = environment["TRON_E2E_TRON_HOME"] else {
            throw XCTSkip("Run through scripts/ios-gateway-e2e-test to provide the real Gateway fixture.")
        }
        let invitation = PairingInvitation(host: "127.0.0.1", port: port, code: code, machineId: "tron-ios-e2e", label: "Tron iOS E2E")
        let (profile, token) = try await GatewayPairer().pair(invitation, deviceName: "Log upload test")
        let client = makeClient()
        _ = try await connectForBoundary(client, profile: profile, token: token)
        let connectionID = try XCTUnwrap(await client.activeConnectionID())
        let marker = "e2e-log-marker-\(UUID().uuidString)"
        let neighbor = "e2e-neighbor-\(UUID().uuidString)"
        let secret = "synthetic-e2e-secret-\(UUID().uuidString.prefix(8))"
        let accessSecret = "synthetic-access-\(UUID().uuidString.prefix(8))"
        let refreshSecret = "synthetic-refresh-\(UUID().uuidString.prefix(8))"
        let clientSecret = "synthetic-client-\(UUID().uuidString.prefix(8))"
        let escapedSecret = "synthetic-escaped-\(UUID().uuidString.prefix(8))"
        let control = String(repeating: "\u{1}", count: 512)
        await AppLog.shared.recordCausal(name: "e2e.log-redaction", outcome: "success",
                                         details: #"{"token":"\#(secret)","access_token":"\#(accessSecret)","refresh_token":"\#(refreshSecret)","client_secret":"\#(clientSecret)","label":"\#(neighbor)","tokenCount":5} \"api_key\":\"\#(escapedSecret)\""#)
        await AppLog.shared.recordRPC(event: control, method: control, requestID: control, outcome: control, code: control,
                                      durationMilliseconds: 1, profileID: control, connectionID: nil)
        await AppLog.shared.recordCausal(name: "e2e.log-marker", outcome: "success", details: marker)
        let uploader = AppLogUploader(log: AppLog.shared, transport: .gateway(client: client) {
            AppLogUploader.Connection(id: connectionID, supportsDeviceLogs: true)
        })
        uploader.start()
        defer { uploader.stop() }
        let devices = URL(fileURLWithPath: tronHome).appendingPathComponent("logs/devices", isDirectory: true)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(25)
        var found = false
        repeat {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []
            found = names.contains { name in
                (try? String(contentsOf: devices.appendingPathComponent(name), encoding: .utf8))?.contains(marker) == true
            }
            if found { break }
            try await Task.sleep(for: .milliseconds(150))
        } while clock.now < deadline
        XCTAssertTrue(found, "the phone log marker must reach the Gateway device file in one upload pass")
        let text = try devices.contentsOfDirectoryText()
        XCTAssertTrue(text.contains(neighbor), "non-secret neighbouring text must survive redaction")
        for value in [secret, accessSecret, refreshSecret, clientSecret, escapedSecret] {
            XCTAssertFalse(text.contains(value), "a secret value must never reach the Gateway device file")
        }
        XCTAssertTrue(text.contains("tokenCount"), "a non-secret key that merely contains a secret word must survive redaction")
        XCTAssertTrue(text.contains("log.record-truncated"), "an oversize record must be replaced by a bounded line, not stall the upload")
    }

    private func assertCorrelationKey(client: GatewayClient) async throws {
        let diagnostics = await client.diagnostics()
        let handshake = try XCTUnwrap(diagnostics.first { $0.stage == .helloReceive && $0.outcome == .success })
        let gatewayConnectionID = try XCTUnwrap(handshake.gatewayConnectionID)
        let epoch = String(try XCTUnwrap(handshake.connectionID))
        let tronHome = try XCTUnwrap(ProcessInfo.processInfo.environment["TRON_E2E_TRON_HOME"])
        let logText = try String(contentsOfFile: tronHome + "/logs/gateway.jsonl", encoding: .utf8)
        let records = logText.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)).objectValue }
        let opened = try XCTUnwrap(records.first {
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

@MainActor
private final class StallingRestoreProjection: GatewayLifecycleProjectionDelegate {
    private(set) var restoreCount = 0
    private(set) var restoring = false
    private var stallArmed = false
    private var restoreContinuation: CheckedContinuation<Void, Never>?

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
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) {}
}

private extension URL {
    func contentsOfDirectoryText() throws -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return try names.map { try String(contentsOf: appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
    }
}

private struct DeviceLogAppendProbe: Encodable {
    let commandId: String
    let bootId: String
    let firstSequence: Int
    let lines: [String]
}
