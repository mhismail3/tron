import SwiftUI

struct TrustSettingsView: View {
    @Environment(AppModel.self) private var model
    let target: TrustTarget?
    @State private var inspection: JSONValue?
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                if let target {
                    TronSettingsGroup("Current Workspace", detail: target.cwd, accent: .tronAmber) {
                        TronStructuredJSONView(value: inspection ?? .null, title: "Project Trust", accent: .tronAmber)
                            .padding(12)
                    }
                    Button("Trust Project") { update(true) }
                        .buttonStyle(TronActionButtonStyle(role: .primary))
                    Button("Do Not Load Project Resources", role: .destructive) { update(false) }
                        .buttonStyle(TronActionButtonStyle(role: .destructive))
                    Button("Clear Saved Decision") { update(nil) }
                        .buttonStyle(TronActionButtonStyle())
                } else {
                    TronGlassCard(accent: .tronSlate) {
                        Text("Open a session to inspect its project trust.")
                            .font(TronTypography.body)
                            .padding(18)
                    }
                }
                Label("Trust gates project-local settings, extensions, skills, prompts, packages, and system prompt files. It is not a sandbox.", systemImage: "exclamationmark.shield")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .padding(14)
                    .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.09)
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Project Trust")
        .task(id: TrustLoadID(target: target, invalidationGeneration: model.trustRevision)) { await load() }
    }
    private func load() async {
        guard let target else { return }
        do {
            let value = try await model.inspectTrust(target: target)
            guard target == self.target else { return }
            inspection = value
        } catch is CancellationError {
            return
        } catch {
            guard target == self.target else { return }
            model.lastError = error.localizedDescription
        }
    }
    private func update(_ decision: Bool?) {
        guard let target else { return }
        Task {
            do {
                let value = try await model.setTrust(target: target, decision: decision)
                guard target == self.target else { return }
                inspection = value
            } catch {
                guard target == self.target else { return }
                model.lastError = error.localizedDescription
            }
        }
    }
}
