import SwiftUI
import TronMobileCore

/// The Home dashboard view's bounds. Every section is a projection of the
/// dashboard's synced session catalog: the Gateway marks Home workers on their
/// rows (`homeTaskId`), so the view issues no reads of its own.
enum HomeDashboardLayout {
    /// Recently Completed and Unread show this many rows, then View more.
    static let sectionRowLimit = 5
    static let floatingButtonSpacing: CGFloat = 12
}

/// One projection of the dashboard catalog into the view's three sections.
/// In Progress and Recently Completed hold Home's workers. Unread is the
/// viewing queue of every settled unread session, worker or ordinary chat:
/// unread is the Gateway's cross-client attention projection
/// (`SessionSummary.isUnread`), cleared when a session is opened, so a
/// completed worker is either still unread or recently completed, never both.
struct HomeDashboardSections: Equatable {
    let inProgress: [SessionSummary]
    let completed: [SessionSummary]
    let unread: [SessionSummary]

    init(sessions: [SessionSummary]) {
        let settled = { (session: SessionSummary) in !(session.phase.isActive || session.waitingForUser) }
        inProgress = sessions.filter { $0.isHomeWorker && !settled($0) }
        completed = sessions.filter { $0.isHomeWorker && settled($0) && !$0.isUnread }
        unread = sessions.filter { $0.isUnread && settled($0) }
    }

    enum Section: String, Hashable, Identifiable {
        case inProgress = "in-progress", completed, unread
        var id: String { rawValue }
    }

    /// The rows a capped section's View more sheet lists.
    func sheetRows(_ section: Section) -> [SessionSummary] {
        switch section {
        case .inProgress: inProgress
        case .completed: completed
        case .unread: unread
        }
    }

    /// Each present section's place in the view's first-appearance stagger.
    /// The usage card above them is order 0; absent sections leave no gap.
    var revealOrder: [Section: Int] {
        var order: [Section: Int] = [:]
        for (section, rows) in [(Section.inProgress, inProgress), (.completed, completed), (.unread, unread)]
        where !rows.isEmpty {
            order[section] = order.count + 1
        }
        return order
    }
}

/// The floating Home button's indicator. It uses the same indicator swap as
/// session rows, so state changes animate identically.
enum HomeButtonIndicatorState: Hashable {
    case resting
    case working
    case waitingForUser

    init(status: HomeStatusDTO?) {
        if status?.waitingForUser == true {
            self = .waitingForUser
        } else if status?.phase == .active {
            self = .working
        } else {
            self = .resting
        }
    }

    var accessibilityValue: String {
        switch self {
        case .resting: "Ready"
        case .working: "Working"
        case .waitingForUser: "Waiting for you"
        }
    }
}

struct HomeFloatingButton: View {
    let state: HomeButtonIndicatorState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DashboardIndicatorSwap(state: state) { state in
                switch state {
                case .resting:
                    Image(systemName: "house.fill")
                        .font(TronTypography.sans(size: 22, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                case .working:
                    ProcessActivityOrb(mode: .solving, size: 30)
                case .waitingForUser:
                    Image(systemName: "questionmark.bubble.fill")
                        .font(TronTypography.sans(size: 22, weight: .semibold))
                        .foregroundStyle(Color.tronAmber)
                }
            }
            .frame(width: 56, height: 56)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tronDashboardFloatingCircle(accent: .tronEmerald)
        .accessibilityLabel("Home")
        .accessibilityValue(state.accessibilityValue)
        .accessibilityIdentifier("home-floating-button")
    }
}

/// The providers the Home usage card can show: every configured provider whose
/// account usage the Gateway supports, in the Providers settings order.
enum HomeUsageProviders {
    @MainActor
    static func all(_ model: AppModel) -> [ProviderSummary] {
        let providers = model.providerCatalog(for: .global)?.providers ?? []
        return ProviderUsageOrdering.sorted(
            ProviderUsageOrdering.visible(providers).filter { $0.configured && $0.supportsUsage }
        )
    }
}

/// This iPhone's choice of which providers the Home usage card shows. It
/// records the hidden ids, so a newly configured provider shows by default.
enum HomeUsageCardPreferences {
    static let hiddenProvidersKey = "dashboard.homeUsage.hiddenProviders.v1"

    static func hidden(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static func toggling(_ providerID: String, in raw: String) -> String {
        var hidden = hidden(raw)
        if hidden.remove(providerID) == nil { hidden.insert(providerID) }
        return hidden.sorted().joined(separator: "\n")
    }
}

/// A concise usage card for the configured providers whose account usage the
/// Gateway supports and that this iPhone shows. It reuses the Providers
/// settings read controller and presentation copy. Tapping it opens
/// `HomeUsageProvidersSheet`.
struct HomeUsageSummaryCard: View {
    let onChooseProviders: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HomeUsageCardPreferences.hiddenProvidersKey) private var hiddenProviders = ""
    @State private var usageController = ProviderUsageReadController()
    /// A failed catalog read hides the card instead of leaving its pulse up.
    @State private var catalogReadFailed = false

    /// Observed from the model's provider catalog, so the card appears as soon
    /// as any owner (this card, Settings, the composer) publishes it.
    private var usageProviders: [ProviderSummary] {
        HomeUsageProviders.all(model)
    }

    private var shownProviders: [ProviderSummary] {
        let hidden = HomeUsageCardPreferences.hidden(hiddenProviders)
        return usageProviders.filter { !hidden.contains($0.id) }
    }

    private var capabilityAvailable: Bool {
        model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true
    }

    /// The card shows while the provider catalog is still being read, so it
    /// holds its place in the view, and stays for as long as a configured
    /// provider supports usage.
    private var showsCard: Bool {
        guard capabilityAvailable else { return false }
        if model.providerCatalog(for: .global) == nil { return !catalogReadFailed }
        return !usageProviders.isEmpty
    }

    /// Only the card's first read shows the pulse: a refresh keeps the
    /// published snapshots on screen until the new ones replace them. With
    /// every provider hidden there is nothing to wait for.
    private var isLoading: Bool {
        guard model.providerCatalog(for: .global) != nil else { return true }
        return !shownProviders.isEmpty && usageController.snapshots.isEmpty && !usageController.hasResolved
    }

    private var accessibilitySummary: String {
        if isLoading { return "Loading account usage" }
        if shownProviders.isEmpty { return "Usage, no providers shown" }
        return shownProviders.map { provider in
            "\(provider.displayName), \(usageController.snapshots[provider.id].map(ProviderUsagePresentation.summary) ?? "usage unavailable")"
        }.joined(separator: "; ")
    }

    var body: some View {
        // A container, not a Group: an empty Group drops the load task below.
        VStack(spacing: 0) {
            if showsCard {
                Button(action: onChooseProviders) {
                    // Once the providers are known their rows lay out hidden under the
                    // pulse, so the card already has its final height when they fade in.
                    ZStack {
                        VStack(alignment: .leading, spacing: 10) {
                            if shownProviders.isEmpty && !isLoading {
                                Text("No providers shown · Tap to choose")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                                    .foregroundStyle(Color.tronTextMuted)
                                    .transition(.opacity)
                            }
                            ForEach(shownProviders, id: \.id) { provider in
                                providerRow(provider)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isLoading ? 0 : 1)
                        if isLoading {
                            TronLoadingState(label: "Loading account usage", accent: .tronEmerald)
                                .transition(TronDashboardContentMotion.transition(reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, SessionDashboardLayout.rowContentHorizontalPadding)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .tronGlassSurface(accent: .tronEmerald, cornerRadius: 12, tintOpacity: 0.14, interactive: true)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint("Choose which providers the card shows")
                .accessibilityIdentifier("home-usage-card")
                .animation(TronDashboardContentMotion.animation(reduceMotion: reduceMotion), value: isLoading)
                .animation(TronDashboardContentMotion.animation(reduceMotion: reduceMotion), value: shownProviders.map(\.id))
            }
        }
        .task(id: PresentationActivityTaskID(
            source: "home-usage:\(model.connectionState == .connected):\(usageProviders.map(\.id).joined(separator: ",")):\(model.providerInvalidationGeneration):\(model.foregroundReconciliationGeneration):\(model.profileRevision):\(usageController.requestGeneration):\(capabilityAvailable)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            await load()
        }
        .onChange(of: model.profileRevision) { _, _ in usageController.begin(clear: true) }
        .onChange(of: model.providerInvalidationGeneration) { _, _ in usageController.begin(clear: true) }
    }

    private func providerRow(_ provider: ProviderSummary) -> some View {
        let snapshot = usageController.snapshots[provider.id]
        return VStack(alignment: .leading, spacing: 4) {
            // The usage line keeps its full size: it trails the name when both
            // fit, else it wraps below the name rather than shrinking.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    providerName(provider)
                    Spacer(minLength: 8)
                    usageLine(snapshot).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    providerName(provider)
                    usageLine(snapshot)
                }
            }
            if isLoading {
                // Hidden layout stand-in for the usage bars.
                ProviderUsageProgress(percent: 0, accent: .tronEmerald)
            } else if let snapshot {
                let percents = snapshot.windows.prefix(2).compactMap(\.usedPercent)
                if !percents.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(percents.enumerated()), id: \.offset) { _, percent in
                            ProviderUsageProgress(percent: percent, accent: .tronEmerald)
                        }
                    }
                }
            }
        }
    }

    private func providerName(_ provider: ProviderSummary) -> some View {
        Text(provider.displayName)
            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            .foregroundStyle(Color.tronTextPrimary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func usageLine(_ snapshot: ProviderUsageSnapshot?) -> some View {
        if isLoading {
            // Static stand-in: the card's pulse is the loading indicator.
            Text(verbatim: ProviderUsagePresentation.loadingPlaceholder)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .redacted(reason: .placeholder)
        } else if let snapshot {
            Text(ProviderUsagePresentation.summary(snapshot))
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(snapshot.status == .available ? Color.tronEmerald : Color.tronTextMuted)
                .monospacedDigit()
                .transition(.opacity)
        } else if !usageController.hasResolved {
            ProviderUsageLoadingLine()
                .transition(.opacity)
        }
    }

    private func load() async {
        // A cold launch mounts before the Gateway connects; the task is keyed on
        // the connection, so it reads again once connected.
        guard presentationActivity.allowsPresentationPublication, !Task.isCancelled,
              model.connectionState == .connected else { return }
        // Read the catalog only when none is published; its arrival re-keys this
        // task (provider ids), which then reads usage.
        guard model.providerCatalog(for: .global) != nil else {
            let refreshed = await model.refreshProviders(target: .global)
            if !Task.isCancelled { catalogReadFailed = !refreshed }
            return
        }
        guard capabilityAvailable, !usageProviders.isEmpty else { return }
        let identity = ProviderUsageReadIdentity(
            target: .global,
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
            fetch: { try await model.client.request("provider.usage", ProviderUsageRequest(sessionId: nil)) },
            current: {
                identity.profileRevision == model.profileRevision
                    && identity.profileID == model.profiles.selected?.id
                    && identity.invalidationGeneration == model.providerInvalidationGeneration
                    && identity.foregroundGeneration == model.foregroundReconciliationGeneration
                    && presentationActivity.allowsPresentationPublication
            }
        )
    }
}

/// Chooses which providers the Home usage card shows, built like the
/// dashboard's Filter sheet.
struct HomeUsageProvidersSheet: View {
    let onDone: () -> Void
    @Environment(AppModel.self) private var model
    @AppStorage(HomeUsageCardPreferences.hiddenProvidersKey) private var hiddenProviders = ""

    var body: some View {
        let hidden = HomeUsageCardPreferences.hidden(hiddenProviders)
        TronDashboardFilterSheet(
            title: "Usage Providers",
            accent: .tronEmerald,
            detents: [.medium, .large],
            onDone: onDone
        ) {
            TronDashboardFilterSectionTitle(
                title: "Providers",
                detail: "Choose the providers whose usage shows on the Home card."
            )
            ForEach(HomeUsageProviders.all(model), id: \.id) { provider in
                TronDashboardFilterOption(
                    title: provider.displayName,
                    selected: !hidden.contains(provider.id),
                    accent: .tronEmerald,
                    inactiveAccent: .tronCyan
                ) {
                    hiddenProviders = HomeUsageCardPreferences.toggling(provider.id, in: hiddenProviders)
                }
                .accessibilityIdentifier("home-usage-provider-\(provider.id)")
            }
        }
    }
}
