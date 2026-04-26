import Foundation

/// Pure-value planner that maps a parsed `PairingURLParser.PairingPayload`
/// to the side-effects the onboarding Pairing step (or the re-pair sheet)
/// must perform on commit. Keeps the decision testable without SwiftUI,
/// dependency container, RPC, or Keychain.
///
/// The caller is responsible for *applying* the plan:
///   1. Write `plan.token` to `PresetTokenStore` keyed on `plan.activePreset.id`.
///   2. Write `plan.activeHost` / `plan.activePort` to UserDefaults under
///      `serverHost` / `serverPort` (the keys `DependencyContainer` reads).
///   3. Push `plan.updatedPresets` to the server via `settings.update` so the
///      array is durable across reinstalls.
///   4. Trigger a reconnect / RPCClient rebuild so the new bearer is picked up.
///
/// **Re-pair vs add**: if `existing` already contains a preset matching
/// `(host, port)` the existing preset is preserved wholesale (id + label)
/// — this matches the AddOrEditServerSheet "edit" mode invariant: the
/// preset id is the Keychain key, so reusing it lets the rotated token
/// land on the same record without orphaning the previous one.
enum PairingPersistor {

    /// The set of side effects to apply for a successful pairing.
    struct Plan: Equatable {
        /// The preset that should be set as the active server (existing if
        /// `(host,port)` already matched, otherwise freshly minted).
        let activePreset: ConnectionPreset
        /// The full preset list to persist to the server (existing + maybe
        /// the new one). Order is preserved with new presets appended.
        let updatedPresets: [ConnectionPreset]
        /// Trimmed bearer token, ready for `PresetTokenStore.setToken`.
        let token: String
        /// Active host string to write to `UserDefaults["serverHost"]`.
        let activeHost: String
        /// Active port string to write to `UserDefaults["serverPort"]`.
        let activePort: String
    }

    /// Compute the side-effect plan for a pairing payload + existing
    /// preset list. Pure — no I/O, deterministic given `idGenerator`.
    static func plan(
        payload: PairingURLParser.PairingPayload,
        existing: [ConnectionPreset],
        idGenerator: () -> String = { UUID().uuidString }
    ) -> Plan {
        let host = payload.host
        let port = payload.port
        let portString = String(port)

        // Re-pair: same (host, port) → preserve preset identity so the
        // Keychain key stays stable across token rotations.
        if let match = existing.first(where: { $0.host == host && $0.port == port }) {
            return Plan(
                activePreset: match,
                updatedPresets: existing,
                token: payload.token,
                activeHost: host,
                activePort: portString
            )
        }

        // New preset. Default label to "My Mac" when payload doesn't carry
        // one — matches the OnboardingState.pairingLabel default so the
        // preset row never reads as unlabeled.
        let label: String = {
            if let provided = payload.label, !provided.isEmpty { return provided }
            return "My Mac"
        }()

        let preset = ConnectionPreset(
            id: idGenerator(),
            label: label,
            host: host,
            port: port
        )
        return Plan(
            activePreset: preset,
            updatedPresets: existing + [preset],
            token: payload.token,
            activeHost: host,
            activePort: portString
        )
    }
}
