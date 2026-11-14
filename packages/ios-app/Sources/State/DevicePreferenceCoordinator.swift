import Foundation
import TronMobileCore

@MainActor
final class DevicePreferenceCoordinator {
    private struct Request: Decodable {
        let requestId: String
        let action: String
        let key: String
        let expected: Bool?
        let value: Bool?
    }

    private struct Reply: Encodable {
        let commandId: String
        let requestId: String
        let status: String
        let value: Bool?
        let current: Bool?
    }

    private let client: GatewayClient
    private let mutationExecutor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource
    private let experiment: SwiftAppExperiment

    init(
        client: GatewayClient,
        mutationExecutor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource,
        experiment: SwiftAppExperiment
    ) {
        self.client = client
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
        self.experiment = experiment
    }

    func handleRequest(_ payload: JSONValue, admission: GatewayLifecycleCoordinator.Admission, profileID: String?) {
        guard let request = try? payload.decode(Request.self),
              request.key == SwiftAppExperiment.devicePreferenceKey else { return }
        let commandID = uuidSource.next().uuidString
        let reply: Reply
        switch request.action {
        case "read":
            reply = Reply(commandId: commandID, requestId: request.requestId, status: "value",
                          value: experiment.isEnabled, current: nil)
        case "set":
            guard let expected = request.expected, let value = request.value else { return }
            switch experiment.compareAndSetDevicePreference(expected: expected, to: value) {
            case .applied:
                reply = Reply(commandId: commandID, requestId: request.requestId, status: "applied",
                              value: nil, current: nil)
            case .conflict(let current):
                reply = Reply(commandId: commandID, requestId: request.requestId, status: "conflict",
                              value: nil, current: current)
            }
        default:
            return
        }
        Task { [weak self] in await self?.respond(reply, admission: admission, profileID: profileID) }
    }

    private func respond(_ reply: Reply, admission: GatewayLifecycleCoordinator.Admission, profileID: String?) async {
        _ = try? await mutationExecutor.performValue(
            method: "device.preference.respond",
            commandID: reply.commandId,
            admission: admission,
            profileID: profileID
        ) {
            try await client.requestValue(
                "device.preference.respond",
                reply,
                expectedConnection: GatewayConnectionAdmission(connectionID: admission.connectionID)
            )
        }
    }
}
