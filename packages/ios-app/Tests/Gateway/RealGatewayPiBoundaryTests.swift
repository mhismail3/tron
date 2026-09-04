import Foundation
import XCTest
@testable import TronMobile

final class RealGatewayPiBoundaryTests: XCTestCase {
    private struct SessionIDResponse: Decodable { let sessionId: String }
    private struct OperationResponse: Decodable { let operationId: String }
    private struct MutationResponse: Decodable { let answered: Bool }
    private struct SyncResponse: Decodable { let synchronized: Bool }
    private struct CloseResponse: Decodable { let closed: Bool }

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
        let firstClient = GatewayClient()
        let firstInfo = try await firstClient.connect(profile: profile, token: token)
        XCTAssertEqual(firstInfo.piVersion, expectedPiVersion, "The iOS boundary must exercise the selected Pi runtime")

        let created: SessionIDResponse = try await firstClient.request(
            "session.create",
            CreateParams(cwd: workspace, commandId: UUID().uuidString),
            timeout: .seconds(30)
        )
        _ = try await synchronizedOpen(client: firstClient, sessionID: created.sessionId)

        let reconnectPrompt = "continue while disconnected"
        let _: OperationResponse = try await firstClient.request(
            "session.prompt",
            PromptParams(
                sessionId: created.sessionId,
                text: reconnectPrompt,
                uploadIds: [],
                behavior: nil,
                commandId: UUID().uuidString
            ),
            timeout: .seconds(15)
        )
        try await waitForStreamingText(
            client: firstClient,
            sessionID: created.sessionId,
            containing: "Streaming response starts now"
        )

        // Admission transfers ownership to the Gateway. Retiring the iOS
        // transport during an observed partial response must not cancel Pi,
        // and a new connection must decode canonical completion rather than
        // rely on buffered events.
        await firstClient.close()

        let reconnectedClient = GatewayClient()
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
