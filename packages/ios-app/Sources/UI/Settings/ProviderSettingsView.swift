import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    let sessionID: String?
    @State private var providers: [ProviderSummary] = []
    @State private var displayedTarget: ProviderCatalogTarget?
    @State private var reloading = false
    @State private var loading = false
    @State private var loadFailed = false
    @State private var loadGeneration = 0
    @State private var manualReloadGeneration = 0

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
                    if loadFailed {
                        TronSettingsNotice(message: "Providers could not be loaded. Check the Gateway connection.", retry: reload)
                    } else {
                        TronSettingsCaption("No providers are available from this Gateway.")
                    }
                } else {
                    ForEach(providers) { provider in
                        ProviderSetupRow(provider: provider, sessionID: sessionID)
                    }
                }
                if let profile = model.profiles.selected {
                    TronSettingsCaption("Provider credentials are stored on \(profile.label) (\(profile.host)).")
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Providers")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronReloadToolbarButton(isReloading: reloading, action: reload)
            }
        }
        .task(id: PresentationActivityTaskID(
            source: "\(target):\(model.providerInvalidationGeneration):\(manualReloadGeneration):\(model.foregroundReconciliationGeneration)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await loadProviders(for: target)
        }
    }

    private func reload() {
        guard !reloading, presentationActivity.allowsPresentationPublication else { return }
        reloading = true
        manualReloadGeneration &+= 1
    }

    private func loadProviders(for requestedTarget: ProviderCatalogTarget) async {
        let foreground = model.foregroundReconciliationGeneration
        guard presentationActivity.allowsPresentationPublication else { return }
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
        defer {
            if generation == loadGeneration, foreground == model.foregroundReconciliationGeneration,
               !Task.isCancelled,
               presentationActivity.allowsPresentationPublication {
                loading = false
                reloading = false
            }
        }

        let succeeded = await model.refreshProviders(target: requestedTarget)
        guard generation == loadGeneration, foreground == model.foregroundReconciliationGeneration,
              requestedTarget == target,
              presentationActivity.allowsPresentationPublication,
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
