import SwiftUI
import TronMobileCore

struct ArchivedSessionsContainerSection: View {
    let count: Int?
    let sources: [ArchivedSessionsProfileSource]
    let profileID: String?
    let projectionRevision: Int
    let presentationActive: Bool
    let loadPage: (String, String?) async throws -> ArchivedSessionsLoadResult
    let onRevealRows: () -> Void
    let onOpen: (CatalogSession) -> Void
    let onUnarchive: (CatalogSession) -> Void
    let onDelete: (CatalogSession) -> Void

    @State private var container = ArchivedSessionsContainerState()
    @State private var loadTask: Task<Void, Never>?
    @State private var loadPass = 0
    @State private var revealPending = false

    var body: some View {
        Group {
            if let count, count > 0 {
                Section {
                    if container.isExpanded {
                        ArchivedSessionsSectionRows(
                            sessions: container.rows,
                            unavailableServerNames: unavailableServerNames,
                            isLoading: container.isLoading,
                            hasMore: container.hasMore,
                            onOpen: onOpen,
                            onUnarchive: onUnarchive,
                            onDelete: onDelete,
                            onShowMore: { startLoad(more: true) }
                        )
                    }
                } header: {
                    ArchivedSessionsSectionHeader(
                        count: count,
                        isExpanded: container.isExpanded,
                        isAwaitingFirstPage: container.isLoading && container.rows.isEmpty,
                        onToggle: toggle
                    )
                }
            }
        }
        .onChange(of: count) { _, value in applyCount(value) }
        .onChange(of: projectionRevision) { _, _ in reloadIfExpanded() }
        .onChange(of: profileID) { _, _ in
            reloadIfExpanded()
        }
        .onChange(of: presentationActive) { _, active in
            if active {
                reloadIfExpanded()
            } else {
                endLoad()
            }
        }
        .onChange(of: container.rows.map(\.dashboardID)) { _, ids in
            guard revealPending, !ids.isEmpty else { return }
            revealPending = false
            onRevealRows()
        }
        .onChange(of: container.isLoading) { _, isLoading in
            if !isLoading, container.rows.isEmpty { revealPending = false }
        }
    }

    private var unavailableServerNames: [String] {
        sources
            .filter { container.unavailableProfileIDs.contains($0.profileID) }
            .map(\.label)
            .sorted()
    }

    private func applyCount(_ count: Int?) {
        guard container.reconcileCount(count) else { return }
        endLoad()
    }

    private func toggle() {
        if container.isExpanded {
            revealPending = false
            endLoad()
            withAnimation(TronDisclosureLayout.expansionAnimation) {
                container.collapse()
            }
            return
        }
        revealPending = true
        withAnimation(TronDisclosureLayout.expansionAnimation) {
            container.expand()
        }
        startLoad(more: false)
    }

    private func reloadIfExpanded() {
        guard container.isExpanded, presentationActive else { return }
        endLoad()
        container.retirePages()
        startLoad(more: false)
    }

    private func endLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func startLoad(more: Bool) {
        guard presentationActive, loadTask == nil else { return }
        container.reconcile(sources)
        let requests = container.pageRequests(for: sources, more: more)
        guard !requests.isEmpty else {
            container.finishLoading()
            revealPending = false
            return
        }
        let generation = container.currentGeneration
        container.beginLoading()
        loadPass &+= 1
        let pass = loadPass
        loadTask = Task { @MainActor in
            defer {
                if loadPass == pass {
                    loadTask = nil
                    if container.isCurrent(generation) { container.finishLoading() }
                }
            }
            var pending = requests
            while let request = pending.first {
                pending.removeFirst()
                guard container.isCurrent(generation) else { return }
                do {
                    let result = try await loadPage(request.profileID, request.cursor)
                    guard container.apply(
                        result,
                        profileID: request.profileID,
                        generation: generation,
                        requestedCursor: request.cursor
                    ) else { continue }
                } catch is CancellationError {
                    return
                } catch {
                    guard container.isCurrent(generation) else { return }
                    if request.cursor != nil, Self.isRefusedCursor(error) {
                        if container.discardCursor(request.profileID) {
                            pending.append((profileID: request.profileID, cursor: nil))
                        }
                        continue
                    }
                    container.markUnavailable(request.profileID)
                }
            }
        }
    }

    private static func isRefusedCursor(_ error: Error) -> Bool {
        guard let failure = error as? GatewayFailure else { return false }
        return failure.code == "invalid_request"
    }
}

struct ArchivedSessionsSectionHeader: View {
    let count: Int
    let isExpanded: Bool
    let isAwaitingFirstPage: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
                leadingIcon
                    .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)
                Text("Archived (\(count))")
                    .font(TronTypography.code(size: TronTypography.sizeBodyLG, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: SessionDashboardLayout.iconTextSpacing)
                TronDisclosureChevron(isExpanded: isExpanded, size: SessionDashboardLayout.headerChevronSize)
            }
            .foregroundStyle(Color.tronPrimary)
            .padding(.leading, SessionDashboardLayout.headerLeadingPadding)
            .padding(.trailing, SessionDashboardLayout.rowContainerHorizontalInset)
            .padding(.top, SessionDashboardLayout.headerTopPadding)
            .padding(.bottom, SessionDashboardLayout.headerBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(TronDisclosureLayout.expansionAnimation, value: isExpanded)
            .animation(TronDisclosureLayout.expansionAnimation, value: isAwaitingFirstPage)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowInsets(SessionDashboardLayout.headerInsets)
        .id(SessionArchiveScrollTarget.headerID)
        .accessibilityIdentifier("archived-sessions-container")
        .accessibilityLabel("Archived")
        .accessibilityValue("\(count)")
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isAwaitingFirstPage {
            ProgressView()
                .controlSize(.small)
                .tint(Color.tronPrimary)
                .transition(.opacity)
                .accessibilityHidden(true)
        } else {
            Image(systemName: isExpanded ? "archivebox.fill" : "archivebox")
                .font(TronTypography.sans(size: SessionDashboardLayout.headerIconSize, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var accessibilityHint: String {
        if isAwaitingFirstPage { return "Loading archived sessions" }
        return isExpanded
            ? "Double tap to hide archived sessions"
            : "Double tap to show archived sessions"
    }
}

enum SessionArchiveScrollTarget {
    static let headerID = "archived-sessions-header"
}

extension ScrollViewProxy {
    @MainActor
    func revealArchivedSection(reduceMotion: Bool) {
        Task { @MainActor in
            withAnimation(TronDashboardContentMotion.animation(reduceMotion: reduceMotion)) {
                scrollTo(SessionArchiveScrollTarget.headerID, anchor: .top)
            }
        }
    }
}

struct ArchivedSessionsSectionRows: View {
    let sessions: [CatalogSession]
    let unavailableServerNames: [String]
    let isLoading: Bool
    let hasMore: Bool
    let onOpen: (CatalogSession) -> Void
    let onUnarchive: (CatalogSession) -> Void
    let onDelete: (CatalogSession) -> Void
    let onShowMore: () -> Void

    var body: some View {
        ForEach(sessions, id: \.dashboardID) { session in
            archivedRow(session)
        }
        ForEach(unavailableServerNames, id: \.self) { name in
            unavailableRow(name)
        }
        if hasMore {
            SessionListExpansionControls(
                workspaceName: "Archived",
                canShowLess: false,
                canShowMore: true,
                isEnabled: !isLoading,
                onShowLess: {},
                onShowMore: onShowMore
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(SessionDashboardLayout.rowInsets)
        }
    }

    private func archivedRow(_ session: CatalogSession) -> some View {
        Button {
            onOpen(session)
        } label: {
            HistoricalSessionRow(session: session, activity: .idle, showsContext: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("archived-session-row-\(session.dashboardID)")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.rowInsets)
        .transition(.opacity)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Unarchive", systemImage: "arrow.uturn.backward") { onUnarchive(session) }
                .tint(Color.gray)
                .accessibilityIdentifier("session-unarchive-action-\(session.dashboardID)")
            Button("Delete", systemImage: "trash") { onDelete(session) }
                .tint(Color.tronError)
                .accessibilityIdentifier("session-delete-action-\(session.dashboardID)")
        }
    }

    private func unavailableRow(_ name: String) -> some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            Image(systemName: "exclamationmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .accessibilityHidden(true)
            Text("Archived sessions unavailable on \(name)")
                .font(TronTypography.settingsRowSubtext)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.tronAmber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SessionDashboardLayout.headerLeadingPadding)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.headerInsets)
    }
}
