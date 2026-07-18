import SwiftUI

/// Engine recovery and pairing remain a local shell. The server-owned product
/// settings below it are rendered through the shared native UI runtime.
struct EngineSettingsPage: View {
    @Environment(\.dependencies) private var dependencies

    let startServerOnboarding: (PairedServer?) -> Void

    init(
        startServerOnboarding: @escaping (PairedServer?) -> Void = {
            ServerOnboardingLauncher.post(prefill: $0)
        }
    ) {
        self.startServerOnboarding = startServerOnboarding
    }

    var body: some View {
        SettingsPageContainer(title: "Engine") {
            EngineServersSection(startServerOnboarding: startServerOnboarding)

            NativeUISurfaceView(
                repository: dependencies.nativeUIRepository,
                request: NativeUISurfaceRequest(
                    definitionId: "settings.engine",
                    surfaceId: "settings.engine"
                ),
                cacheNamespace: cacheNamespace,
                onTreeChange: applySessionDefaults
            )
            .id("\(dependencies.activeServerSelectionVersion):\(dependencies.nativeUISurfaceRefreshVersion)")
            .disabled(dependencies.pairedServerStore.activeServer == nil)
            .opacity(dependencies.pairedServerStore.activeServer == nil ? 0.55 : 1)
            .accessibilityIdentifier("native-ui.settings.engine")
        }
    }

    private var cacheNamespace: String {
        dependencies.pairedServerStore.activeServer?.id ?? "unpaired"
    }

    private func applySessionDefaults(_ tree: NativeUISurfaceTree) {
        guard let workspace = tree.value(at: "/defaultWorkspace")?.stringValue,
              let model = tree.value(at: "/defaultModel")?.stringValue
        else { return }
        dependencies.applySessionDefaultsSnapshot(.init(
            defaultWorkspace: workspace,
            defaultModel: model
        ))
    }
}
