import SwiftUI

// MARK: - Environment wiring

/// SwiftUI environment access for the shared `InteractionPolicy`.
///
/// Install once at the root (`TronMobileApp`) and read in any view that needs to gate
/// mutation actions:
///
/// ```swift
/// @Environment(\.interactionPolicy) var policy
/// Button("Send") { ... }
///     .disabled(!(policy?.canSendMessage ?? false))  // fail closed when absent
/// ```
///
/// The default value is `nil` so views rendered outside the environment (previews,
/// unconfigured tests) fail closed (read-only) rather than allowing mutations.
private struct InteractionPolicyKey: EnvironmentKey {
    static let defaultValue: InteractionPolicy? = nil
}

extension EnvironmentValues {
    var interactionPolicy: InteractionPolicy? {
        get { self[InteractionPolicyKey.self] }
        set { self[InteractionPolicyKey.self] = newValue }
    }
}
