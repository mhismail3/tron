import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String?
    @State private var reloading = false

    private var target: ProviderCatalogTarget {
        sessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 6) {
                ForEach(model.providerCatalog(for: target)?.providers ?? []) { provider in
                    ProviderSetupRow(provider: provider, sessionID: sessionID)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Providers")
        // Provider login must be presented by the currently visible provider
        // sheet, not by Settings or the dashboard underneath its sheet stack.
        .providerAuthPresenter()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronReloadToolbarButton(isReloading: reloading, action: reload)
            }
        }
        .task(id: ProviderCatalogLoadID(target: target, invalidationGeneration: model.providerInvalidationGeneration)) {
            await model.refreshProviders(target: target)
        }
    }

    private func reload() {
        guard !reloading else { return }
        reloading = true
        Task {
            defer { reloading = false }
            await model.refreshProviders(target: target)
        }
    }
}
