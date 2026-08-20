import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String?
    @State private var providers: [ProviderSummary] = []
    @State private var displayedTarget: ProviderCatalogTarget?
    @State private var reloading = false
    @State private var loading = false
    @State private var loadFailed = false
    @State private var loadGeneration = 0

    private var target: ProviderCatalogTarget {
        sessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 6) {
                if loading && providers.isEmpty {
                    TronLoadingState(label: "Loading providers…", accent: .tronEmerald)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if providers.isEmpty {
                    TronInfoCard(
                        icon: loadFailed ? "exclamationmark.triangle" : "key",
                        text: loadFailed
                            ? "Providers could not be loaded. Check the Gateway connection and try Reload."
                            : "No providers are available from this Gateway.",
                        accent: loadFailed ? .tronAmber : .tronSlate
                    )
                } else {
                    ForEach(providers) { provider in
                        ProviderSetupRow(provider: provider, sessionID: sessionID)
                    }
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
            await loadProviders(for: target)
        }
    }

    private func reload() {
        guard !reloading else { return }
        Task { await loadProviders(for: target, manual: true) }
    }

    private func loadProviders(for requestedTarget: ProviderCatalogTarget, manual: Bool = false) async {
        loadGeneration &+= 1
        let generation = loadGeneration

        if displayedTarget != requestedTarget {
            displayedTarget = requestedTarget
            providers = []
            loadFailed = false
        }

        // Publish an already-authoritative catalog synchronously. A reconnect or
        // competing settings refresh may revoke the network request, but should
        // never blank a useful catalog that this visible sheet already owns.
        if let existing = model.providerCatalog(for: requestedTarget)?.providers {
            providers = existing
        }

        loading = providers.isEmpty
        if manual { reloading = true }
        defer {
            if generation == loadGeneration {
                loading = false
                reloading = false
            }
        }

        let succeeded = await model.refreshProviders(target: requestedTarget)
        guard generation == loadGeneration,
              requestedTarget == target,
              !Task.isCancelled else { return }

        if let catalog = model.providerCatalog(for: requestedTarget) {
            providers = catalog.providers
            loadFailed = false
        } else if !succeeded {
            // Retain the last successful bounded projection rather than flashing
            // an empty sheet during transient reconnect/catalog invalidation.
            loadFailed = providers.isEmpty
        }
    }
}
