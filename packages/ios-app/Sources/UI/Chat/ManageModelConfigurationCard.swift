import SwiftUI
import TronMobileCore

/// One model card for both Manage surfaces. It restores the former header and
/// three controls without reviving a second mutation/pending-state owner.
struct ManageModelConfigurationCard: View {
    static let keys: Set<String> = ["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow"]
    let sessionID: String
    var home = false

    private var target: JSONValue {
        home ? .object(["kind": .string("home")]) : SettingsTarget.sessionGatewayTarget(sessionID)
    }

    var body: some View {
        TronGlassCard(accent: .tronPrimary) {
            SettingsRendererView(target: target, writeLayer: nil, ownedLayers: ["session"],
                presentation: .keys(["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow"]),
                embedded: true, modelConfiguration: true)
        }
        .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(home ? "home-model-summary" : "session-model-summary")
    }
}
