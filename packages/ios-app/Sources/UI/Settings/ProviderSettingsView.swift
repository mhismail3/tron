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
    @State private var usageController = ProviderUsageReadController()

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
                    let configured = ProviderUsageOrdering.sorted(providers.filter(\.configured))
                    let available = ProviderUsageOrdering.sorted(providers.filter { !$0.configured })
                    if !configured.isEmpty {
                        providerSection("Configured", providers: configured)
                    }
                    if !available.isEmpty {
                        providerSection("Available", providers: available)
                    }
                    if model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) != true {
                        TronSettingsCaption("Account usage is unavailable on this Gateway.")
                    } else if usageController.isLoading {
                        TronSettingsCaption("Refreshing account usage…")
                    } else if usageController.didFail {
                        TronSettingsCaption("Account usage is currently unavailable. Connection details remain available.")
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
            source: "\(target):\(model.providerInvalidationGeneration):\(manualReloadGeneration):\(model.foregroundReconciliationGeneration):\(model.profileRevision):\(usageController.requestGeneration):\(model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication, !Task.isCancelled else { return }
            guard await loadProviders(for: target),
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication,
                  target == self.target else { return }
            await loadUsage(for: target)
        }
        .onChange(of: model.profileRevision) { _, _ in
            usageController.begin(clear: true)
        }
        .onChange(of: model.providerInvalidationGeneration) { _, _ in
            usageController.begin(clear: true)
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            guard active else {
                // The parent is covered while a provider detail sheet loads.
                // Retire its request, but keep same-target snapshots mounted so
                // the provider row's usage line remains visually continuous.
                usageController.begin()
                return
            }
        }
    }

    @ViewBuilder
    private func providerSection(
        _ title: String,
        providers: [ProviderSummary]
    ) -> some View {
        TronSettingsGroup(
            title,
            accent: .tronPurple,
            surfaceStyle: .glass
        ) {
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                ProviderSetupRow(
                    surfaceStyle: .grouped,
                    provider: provider,
                    sessionID: sessionID,
                    usageSnapshot: usageController.snapshots[provider.id],
                    isUsageLoading: showsUsageLoadingLine(for: provider)
                )
                if index < providers.count - 1 {
                    TronSettingsDivider(accent: .tronPurple)
                }
            }
        }
        .padding(.top, title == "Available" ? TronSpacing.section : 0)
    }

    private func reload() {
        guard !reloading, presentationActivity.allowsPresentationPublication else { return }
        reloading = true
        manualReloadGeneration &+= 1
    }

    /// Rows the Gateway reports as first-party usage capable reserve their usage
    /// line while the bounded read is pending. The Gateway owns that support set
    /// so the client never duplicates the adapter table.
    private func showsUsageLoadingLine(for provider: ProviderSummary) -> Bool {
        ProviderUsagePresentation.showsUsageLoadingLine(
            snapshot: usageController.snapshots[provider.id],
            configured: provider.configured,
            usageSupported: provider.supportsUsage,
            capabilityAvailable: model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true,
            readResolved: usageController.hasResolved
        )
    }

    private func loadProviders(for requestedTarget: ProviderCatalogTarget) async -> Bool {
        let profile = model.profileRevision
        let profileID = model.profiles.selected?.id
        let foreground = model.foregroundReconciliationGeneration
        guard presentationActivity.allowsPresentationPublication, !Task.isCancelled else { return false }
        loadGeneration &+= 1
        let generation = loadGeneration

        if displayedTarget != requestedTarget {
            displayedTarget = requestedTarget
            providers = []
            usageController.reset(clear: true)
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
            if !Task.isCancelled,
               generation == loadGeneration, profile == model.profileRevision,
               profileID == model.profiles.selected?.id,
               foreground == model.foregroundReconciliationGeneration,
               requestedTarget == target,
               presentationActivity.allowsPresentationPublication {
                loading = false
                reloading = false
            }
        }

        let succeeded = await model.refreshProviders(target: requestedTarget)
        guard !Task.isCancelled,
              generation == loadGeneration, profile == model.profileRevision,
              profileID == model.profiles.selected?.id,
              foreground == model.foregroundReconciliationGeneration,
              requestedTarget == target,
              presentationActivity.allowsPresentationPublication,
              !Task.isCancelled else { return false }

        if let catalog = model.providerCatalog(for: requestedTarget) {
            providers = catalog.providers
            loadFailed = false
        } else if !succeeded {
            // Retain the last successful bounded projection rather than flashing
            // an empty sheet during transient reconnect/catalog invalidation.
            loadFailed = providers.isEmpty
        }
        return true
    }

    private func loadUsage(for requestedTarget: ProviderCatalogTarget) async {
        guard model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true,
              presentationActivity.allowsPresentationPublication,
              requestedTarget == target,
              !Task.isCancelled else { return }
        let identity = ProviderUsageReadIdentity(
            target: requestedTarget,
            providerID: nil,
            profileRevision: model.profileRevision,
            profileID: model.profiles.selected?.id,
            invalidationGeneration: model.providerInvalidationGeneration,
            foregroundGeneration: model.foregroundReconciliationGeneration,
            requestGeneration: usageController.requestGeneration,
            presentationActive: presentationActivity.allowsPresentationPublication
        )
        await usageController.read(
            identity: identity,
            fetch: {
                try await model.client.request(
                    "provider.usage",
                    ProviderUsageRequest(sessionId: requestedTarget.sessionID)
                )
            },
            current: {
                requestedTarget == self.target
                    && identity.profileRevision == model.profileRevision
                    && identity.profileID == model.profiles.selected?.id
                    && identity.invalidationGeneration == model.providerInvalidationGeneration
                    && identity.foregroundGeneration == model.foregroundReconciliationGeneration
                    && presentationActivity.allowsPresentationPublication
            }
        )
    }
}
