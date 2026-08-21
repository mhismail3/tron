import SwiftUI

private struct ExtensionActivityDetailRoute: Identifiable, Hashable {
    let id: String
    let mountedActivity: ExtensionRunActivity?
}

private struct ExtensionActivityDetailContainer: View {
    let sessionID: String
    let route: ExtensionActivityDetailRoute
    let store: SessionExtensionActivityStore?

    var body: some View {
        ExtensionRunDetailsSheet(
            sessionID: sessionID,
            activityID: route.id,
            activityOverride: route.mountedActivity ?? (store?.detailRouteID == route.id ? store?.detail : nil)
        )
        .task(id: route.id) {
            guard route.mountedActivity == nil else { return }
            store?.loadDetail(sessionID: sessionID, activityID: route.id,
                              presentationGeneration: store?.presentationGeneration ?? 0,
                              routeID: route.id)
        }
    }
}

struct ExtensionActivityHistorySheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store: SessionExtensionActivityStore?
    @State private var generation = 0

    var body: some View {
        Group {
            if let store { history(store) }
            else { TronLoadingState(label: "Preparing extension history…") }
        }
        .navigationTitle("Extension Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .navigationDestination(for: ExtensionActivityDetailRoute.self) { route in
            ExtensionActivityDetailContainer(sessionID: sessionID, route: route, store: store)
        }
        .task(id: model.presentationGeneration(for: sessionID)) {
            guard let target = model.presentationTarget(for: sessionID) else { return }
            generation = target.generation
            if store == nil { store = SessionExtensionActivityStore(client: model.client) }
            store?.reset(sessionID: sessionID, presentationGeneration: target.generation)
            store?.loadNext(sessionID: sessionID, presentationGeneration: target.generation)
        }
        .onChange(of: mountedOwnerSignature) { old, new in
            guard old != new, !old.isEmpty, !Set(old).isSubset(of: Set(new)),
                  let target = model.presentationTarget(for: sessionID) else { return }
            store?.reset(sessionID: sessionID, presentationGeneration: target.generation)
            store?.loadNext(sessionID: sessionID, presentationGeneration: target.generation)
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("extension-activity-history-sheet")
    }

    private var mountedOwnerSignature: [String] {
        mountedActivities.map { $0.source.owner?.id ?? "source:\($0.source.source)" }.sorted()
    }

    private var mountedActivities: [ExtensionRunActivity] {
        guard let snapshot = model.authoritativeSnapshot(for: sessionID) else { return [] }
        var seen = Set<String>()
        return (snapshot.extensionActivities ?? []).filter {
            ExtensionActivityAdmissionPolicy.admits($0)
                && ExtensionActivityVisibilityPolicy.ambient($0)
                && seen.insert($0.stableID).inserted
        }
    }

    @ViewBuilder private func history(_ store: SessionExtensionActivityStore) -> some View {
        let mounted = mountedActivities
        let current = mounted.filter { ExtensionActivityVisibilityPolicy.authoritativeBucket($0) == .current }
        let recent = mounted.filter { ExtensionActivityVisibilityPolicy.authoritativeBucket($0) == .recent }
        let mountedIDs = Set(mounted.map(\.stableID))
        let earlier = store.activities.filter { !mountedIDs.contains($0.stableID) }
        let hasMounted = !mounted.isEmpty

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !current.isEmpty { activitySection("Current", current, accent: .tronEmerald, fetchDetail: false) }
                if !recent.isEmpty { activitySection("Recently completed", recent, accent: .tronAmber, fetchDetail: false) }
                if !earlier.isEmpty { activitySection("Earlier activity", earlier, accent: .tronCyan, fetchDetail: true) }

                if store.status == .conflict {
                    ContentUnavailableView("History changed", systemImage: "arrow.triangle.2.circlepath", description: Text("Reload to continue from the latest canonical page."))
                    Button("Reload history") { store.retryReload(sessionID: sessionID, presentationGeneration: generation) }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                } else if store.status == .unavailable {
                    fallbackMessage("History unavailable on this Gateway", detail: hasMounted ? "Current and recent mounted activity remains available above." : "Current activity appears when a session is mounted.", systemImage: "externaldrive.badge.questionmark")
                } else if store.status == .disconnected {
                    fallbackMessage("Gateway disconnected", detail: hasMounted ? "Mounted activity remains available. Reconnect to load canonical history." : "Reconnect to load canonical history.", systemImage: "wifi.slash")
                } else if case .failed(let message) = store.status {
                    fallbackMessage("Unable to load history", detail: message, systemImage: "exclamationmark.triangle")
                } else if store.status == .idle || (store.status == .loading && store.activities.isEmpty && !hasMounted) {
                    TronLoadingState(label: "Loading extension history…")
                } else if !hasMounted && earlier.isEmpty && store.status == .loaded {
                    ContentUnavailableView("No recorded extension activity", systemImage: "clock.arrow.circlepath", description: Text("Completed lifecycle receipts will appear here."))
                }

                if store.nextCursor != nil {
                    Button("Load More") { store.loadNext(sessionID: sessionID, presentationGeneration: generation) }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .disabled(store.status == .loading)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder private func activitySection(_ title: String, _ activities: [ExtensionRunActivity], accent: Color, fetchDetail: Bool) -> some View {
        Text(title).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).padding(.top, 4)
        ForEach(activities) { activityRow($0, accent: accent, fetchDetail: fetchDetail) }
    }

    private func activityRow(_ activity: ExtensionRunActivity, accent: Color, fetchDetail: Bool) -> some View {
        NavigationLink(value: ExtensionActivityDetailRoute(id: activity.stableID, mountedActivity: fetchDetail ? nil : activity)) {
            HStack {
                Image(systemName: activity.lifecycle?.isTerminal == true ? "checkmark.circle" : "circle.dotted")
                VStack(alignment: .leading) {
                    Text(activity.title).lineLimit(1)
                    Text(historySummary(activity)).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(TronTypography.caption)
            }
            .padding(12)
            .tronGlassSurface(accent: accent, tintOpacity: 0.1, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func fallbackMessage(_ title: String, detail: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
    }

    private func historySummary(_ activity: ExtensionRunActivity) -> String {
        let state = activity.lifecycle?.state.displayName ?? (activity.status == .failed ? "Failed" : "Completed")
        return [state, activity.toolCount.map { "\($0) tools" }, activity.turnCount.map { "\($0) turns" }].compactMap { $0 }.joined(separator: " · ")
    }
}
