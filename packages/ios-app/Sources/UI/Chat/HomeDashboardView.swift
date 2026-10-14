import SwiftUI
import TronMobileCore

/// The Home dashboard view's bounds. Every section is a projection of the
/// dashboard's synced session catalog: the Gateway marks Home workers on their
/// rows (`homeTaskId`), so the view issues no reads of its own.
enum HomeDashboardLayout {
    static let recentlyCompletedLimit = 5
    static let floatingButtonSpacing: CGFloat = 12
}

/// One projection of the dashboard catalog into the view's three sections.
/// In Progress and Recently Completed hold Home's workers. Unviewed is the
/// viewing queue of every settled unread session, worker or ordinary chat:
/// unread is the Gateway's cross-client attention projection
/// (`SessionSummary.isUnread`), cleared when a session is opened, so a
/// completed worker is either still unviewed or recently completed, never both.
struct HomeDashboardSections: Equatable {
    let inProgress: [SessionSummary]
    let completed: [SessionSummary]
    let unviewed: [SessionSummary]

    init(sessions: [SessionSummary]) {
        let settled = { (session: SessionSummary) in !(session.phase.isActive || session.waitingForUser) }
        inProgress = sessions.filter { $0.isHomeWorker && !settled($0) }
        completed = sessions.filter { $0.isHomeWorker && settled($0) && !$0.isUnread }
        unviewed = sessions.filter { $0.isUnread && settled($0) }
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

/// A concise usage card for every configured provider whose account usage the
/// Gateway supports. It reuses the Providers settings read controller and
/// presentation copy; providers without usage support are omitted.
struct HomeUsageSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var usageController = ProviderUsageReadController()

    /// Observed from the model's provider catalog, so the card appears as soon
    /// as any owner (this card, Settings, the composer) publishes it.
    private var providers: [ProviderSummary] {
        model.providerCatalog(for: .global)?.providers ?? []
    }

    private var usageProviders: [ProviderSummary] {
        ProviderUsageOrdering.sorted(
            ProviderUsageOrdering.visible(providers).filter { $0.configured && $0.supportsUsage }
        )
    }

    private var capabilityAvailable: Bool {
        model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true
    }

    var body: some View {
        // A container, not a Group: an empty Group drops the load task below.
        VStack(spacing: 0) {
            if capabilityAvailable && !usageProviders.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(usageProviders, id: \.id) { provider in
                        providerRow(provider)
                    }
                }
                .padding(.horizontal, SessionDashboardLayout.rowContentHorizontalPadding)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tronGlassSurface(accent: .tronEmerald, cornerRadius: 12, tintOpacity: 0.14)
                .accessibilityIdentifier("home-usage-card")
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
            if let snapshot {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName), \(snapshot.map(ProviderUsagePresentation.summary) ?? "usage loading")")
    }

    private func providerName(_ provider: ProviderSummary) -> some View {
        Text(provider.displayName)
            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            .foregroundStyle(Color.tronTextPrimary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func usageLine(_ snapshot: ProviderUsageSnapshot?) -> some View {
        if let snapshot {
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
            _ = await model.refreshProviders(target: .global)
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
