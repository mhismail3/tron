#if HOSTED_TEST
import SwiftUI

@MainActor
final class ModelPickerHostedProbe {
    private struct Action {
        let token: UUID
        let run: () -> Void
    }

    private var actions: [String: Action] = [:]

    func contains(_ id: String) -> Bool { actions[id] != nil }

    func install(_ id: String, token: UUID, action: @escaping () -> Void) {
        actions[id] = Action(token: token, run: action)
    }

    func retire(_ id: String, token: UUID) {
        if actions[id]?.token == token { actions[id] = nil }
    }

    @discardableResult
    func activate(_ id: String) -> Bool {
        guard let action = actions[id] else { return false }
        action.run()
        return true
    }
}

private struct ModelPickerHostedProbeKey: EnvironmentKey {
    static let defaultValue: ModelPickerHostedProbe? = nil
}

extension EnvironmentValues {
    var modelPickerHostedProbe: ModelPickerHostedProbe? {
        get { self[ModelPickerHostedProbeKey.self] }
        set { self[ModelPickerHostedProbeKey.self] = newValue }
    }
}

struct ModelPickerHostedActionModifier: ViewModifier {
    let id: String
    let action: () -> Void
    @Environment(\.modelPickerHostedProbe) private var probe
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { probe?.install(id, token: token, action: action) }
            .onDisappear { probe?.retire(id, token: token) }
    }
}
#endif
