#if HOSTED_TEST
import SwiftUI

/// Hosted tests invoke the same mounted callback supplied to the control.
/// This is not touch/VoiceOver automation and is absent from application builds.
@MainActor
final class HostedToolActionProbe {
    private var actions: [String: (UUID, () -> Void)] = [:]
    var count: Int { actions.count }
    func contains(_ id: String) -> Bool { actions[id] != nil }
    func install(_ id: String, token: UUID, action: @escaping () -> Void) { actions[id] = (token, action) }
    func retire(_ id: String, token: UUID) {
        if actions[id]?.0 == token { actions[id] = nil }
    }
    func activate(_ id: String) -> Bool {
        guard let action = actions[id]?.1 else { return false }
        action()
        return true
    }
}
private struct HostedToolActionProbeKey: EnvironmentKey {
    static let defaultValue: HostedToolActionProbe? = nil
}
extension EnvironmentValues {
    var hostedToolActionProbe: HostedToolActionProbe? {
        get { self[HostedToolActionProbeKey.self] }
        set { self[HostedToolActionProbeKey.self] = newValue }
    }
}
struct HostedToolActionProbeModifier: ViewModifier {
    let id: String
    let action: () -> Void
    @Environment(\.hostedToolActionProbe) private var probe
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content.onAppear { probe?.install(id, token: token, action: action) }
            .onDisappear { probe?.retire(id, token: token) }
    }
}
#endif
