import Foundation
import TronMobileCore

extension InstalledSwiftApps {
    /// The one composition of the selected Gateway's installed-app ports. Every
    /// read pins the selected profile and connection epoch and requires that
    /// admission after its await; every mutation is a stable-command receipt.
    @MainActor
    static func gateway(
        client: GatewayClient,
        lifecycle: GatewayLifecycleCoordinator,
        mutations: ConfirmedMutationExecutor
    ) -> InstalledSwiftApps {
        func read<P: Encodable & Sendable, R: Decodable & Sendable>(_ profileID: String, _ method: String, _ params: P, as: R.Type = R.self) async throws -> R {
            guard lifecycle.selectedProfileID == profileID, let admission = lifecycle.admission,
                  let connectionID = admission.connectionID else { throw CancellationError() }
            let value: R = try await client.request(method, params, expectedEpochID: connectionID)
            try lifecycle.require(admission)
            return value
        }
        func mutate<P: Encodable & Sendable, R: Codable & Sendable>(_ profileID: String, _ method: String, _ commandID: String, _ params: P) async throws -> R {
            guard lifecycle.selectedProfileID == profileID else { throw CancellationError() }
            return try await mutations.perform(method: method, commandID: commandID,
                replayAdmission: { lifecycle.selectedProfileID == profileID }) {
                guard lifecycle.selectedProfileID == profileID else { throw CancellationError() }
                guard let connectionID = lifecycle.connectionID else {
                    throw GatewayDefinitelyNotSentError(failure: GatewayFailure(code: "disconnected",
                        message: "The app's Gateway is reconnecting. Your change was not sent.", retryable: true, details: nil))
                }
                return try await client.request(method, params, expectedEpochID: connectionID)
            }
        }
        struct Id: Encodable { let appId: String }
        struct Empty: Encodable {}
        struct Rename: Encodable { let commandId: String; let appId: String; let name: String }
        struct Reset: Encodable { let commandId: String; let appId: String; let expectedRevision: Int }
        struct Reverted: Codable { let appId: String; let revision: Int }
        func command() -> String { UUID().uuidString.lowercased() }
        return InstalledSwiftApps(ports: Ports(
            list: { profileID in try await read(profileID, "apps.list", Empty(), as: InstalledSwiftAppList.self) },
            open: { profileID, appID in try await read(profileID, "apps.open", Id(appId: appID)) },
            commit: { profileID, commit in try await mutate(profileID, "apps.commit", commit.commandId, commit) },
            rename: { profileID, appID, name in
                let id = command()
                return (try await mutate(profileID, "apps.rename", id, Rename(commandId: id, appId: appID, name: name)) as InstalledSwiftAppRenamed).app
            },
            reset: { profileID, appID, revision in
                let id = command()
                let _: Reverted = try await mutate(profileID, "apps.reset", id, Reset(commandId: id, appId: appID, expectedRevision: revision))
            },
            state: { profileID, appID in
                (try await read(profileID, "apps.state", Id(appId: appID), as: InstalledSwiftAppStateRevision.self)).revision
            }
        ))
    }
}
