import Foundation

/// Pure-value planner that maps a parsed `PairingURLParser.PairingPayload`
/// to the side effects the onboarding Pairing step must perform on commit.
/// Keeps the decision testable without SwiftUI, dependency container, RPC, or
/// Keychain.
///
/// The caller is responsible for *applying* the plan:
///   1. Write `plan.token` to `PairedServerTokenStore` keyed on `plan.activeServer.id`.
///   2. Persist `plan.updatedServers` to `PairedServerStore` with
///      `plan.activeServer` selected.
///   3. Rebuild/reconnect the RPC client so the new bearer is picked up.
///
/// **Re-pair vs add**: if `existing` already contains a server matching
/// `(host, port)` the existing server is preserved wholesale (id + label).
/// The server id is the Keychain key, so reusing it lets the rotated token
/// land on the same record without orphaning the previous one.
enum PairingPersistor {

    /// The set of side effects to apply for a successful pairing.
    struct Plan: Equatable {
        /// The server that should be set as active (existing if
        /// `(host,port)` already matched, otherwise freshly minted).
        let activeServer: PairedServer
        /// The full local server list to persist. Order is preserved with new
        /// servers appended.
        let updatedServers: [PairedServer]
        /// Trimmed bearer token, ready for `PairedServerTokenStore.setToken`.
        let token: String
    }

    /// Compute the side-effect plan for a pairing payload + existing
    /// local server list. Pure — no I/O, deterministic given `idGenerator`.
    static func plan(
        payload: PairingURLParser.PairingPayload,
        existing: [PairedServer],
        idGenerator: () -> String = { UUID().uuidString }
    ) -> Plan {
        let host = payload.host
        let port = payload.port

        // Re-pair: same (host, port) → preserve server identity so the
        // Keychain key stays stable across token rotations.
        if let match = existing.first(where: { $0.host == host && $0.port == port }) {
            return Plan(
                activeServer: match,
                updatedServers: existing,
                token: payload.token
            )
        }

        // New server. Default label to "My Mac" when payload doesn't carry
        // one — matches the OnboardingState.pairingLabel default so the
        // server row never reads as unlabeled.
        let label: String = {
            if let provided = payload.label, !provided.isEmpty { return provided }
            return "My Mac"
        }()

        let server = PairedServer(
            id: idGenerator(),
            label: label,
            host: host,
            port: port
        )
        return Plan(
            activeServer: server,
            updatedServers: existing + [server],
            token: payload.token
        )
    }
}
