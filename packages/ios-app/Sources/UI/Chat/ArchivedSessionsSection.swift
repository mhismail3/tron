import SwiftUI
import TronMobileCore

/// The dashboard's archived container. Visibility, the zero-count collapse, the
/// profile-switch pass, and the page reads live here rather than in a caller's
/// body, so the dashboard and the hosted journey drive the same control flow.
/// Every read is a disposable presentation read: it is checked against the
/// owner's exact latest-request generation and the caller's managed activity
/// before it publishes, and a retired pass publishes nothing.
struct ArchivedSessionsContainerSection: View {
    /// The summed Gateway count across archive-capable servers. `nil` means no
    /// capable server has published a count yet, which the dashboard never
    /// presents as a fabricated zero.
    let count: Int?
    let sources: [ArchivedSessionsProfileSource]
    /// The dashboard's focused profile. Reads are fenced per profile, so a
    /// switch re-reads instead of collapsing the user's expansion.
    let profileID: String?
    /// Advances when the Gateway's archive projection changes: an authoritative
    /// dashboard page, or a capable server's count. The container re-reads only
    /// on these, so an agent run's summary stream cannot loop its page reads.
    let projectionRevision: Int
    let presentationActive: Bool
    /// One page from one server, under the caller's own read fence.
    let loadPage: (String, String?) async throws -> ArchivedSessionsLoadResult
    /// Scrolls the dashboard list so the rows the user just asked for are in
    /// view. The list owner supplies it, because it owns the scroll position.
    let onRevealRows: () -> Void
    let onOpen: (SessionSummary) -> Void
    let onUnarchive: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void

    @State private var container = ArchivedSessionsContainerState()
    @State private var loadTask: Task<Void, Never>?
    /// Identifies the installed pass. A pass retires only the handle it owns,
    /// so a cancel-and-reload installs a newer one this pass must not clear.
    @State private var loadPass = 0
    /// True between the user's own expansion and the first rows it publishes.
    /// Only that moment reveals rows, so a background reload, a profile switch,
    /// or "Show more" never scrolls the list under the user.
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
                        // The expansion's first rows replace the placeholder row
                        // the container used to show, so the header's leading
                        // icon is the whole loading affordance.
                        isAwaitingFirstPage: container.isLoading && container.rows.isEmpty,
                        onToggle: toggle
                    )
                }
            }
        }
        .onChange(of: count) { _, value in applyCount(value) }
        .onChange(of: projectionRevision) { _, _ in reloadIfExpanded() }
        .onChange(of: profileID) { _, _ in
            // A profile switch keeps the user's expansion: every row is
            // qualified by the server it came from, so the pass is re-read
            // against the new source set instead of being thrown away.
            reloadIfExpanded()
        }
        .onChange(of: presentationActive) { _, active in
            // Leaving the dashboard retires the pass; returning to it re-reads an
            // already-expanded container instead of presenting pre-exit pages.
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
            // A pass that ends without a row reveals nothing, and the flag must
            // not survive into a later background publication.
            if !isLoading, container.rows.isEmpty { revealPending = false }
        }
    }

    private var unavailableServerNames: [String] {
        sources
            .filter { container.unavailableProfileIDs.contains($0.profileID) }
            .map(\.label)
            .sorted()
    }

    /// A count of zero means no archived session exists on any capable server,
    /// so the container closes instead of polling pages nobody can see.
    private func applyCount(_ count: Int?) {
        guard container.reconcileCount(count) else { return }
        endLoad()
    }

    private func toggle() {
        if container.isExpanded {
            // Collapsing retires the pass: a page already in flight must never
            // publish into a closed container.
            revealPending = false
            endLoad()
            withAnimation(TronDisclosureLayout.expansionAnimation) {
                container.collapse()
            }
            return
        }
        // The user's own expansion is the only moment the list may move.
        revealPending = true
        withAnimation(TronDisclosureLayout.expansionAnimation) {
            container.expand()
        }
        startLoad(more: false)
    }

    private func reloadIfExpanded() {
        guard container.isExpanded, presentationActive else { return }
        // A newer archive authority replaces a pass that is still reading, so
        // the pass is retired and a fresh first-page pass starts. Dropping the
        // reload while a page is in flight would leave the container showing
        // rows the Gateway has already superseded.
        endLoad()
        container.retirePages()
        startLoad(more: false)
    }

    /// Cancels the installed pass. Retirement is the container's job, not the
    /// handle's: cancellation is cooperative, so a page already read is refused
    /// by the pass generation instead.
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
            // Nothing readable to reveal: drop the pending reveal rather than
            // let it move the list on some later background publication.
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
            // A refused continuation is replaced by that server's first page, so
            // the work list can grow while the pass runs.
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
                        // The Gateway no longer knows this cursor, so retrying it
                        // can never succeed: start this server over from its
                        // first page and keep the rows already shown.
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

    /// A continuation the Gateway refuses with `invalid_request` names a cursor
    /// it no longer accepts: expired, evicted, or bound to a retired page lease.
    private static func isRefusedCursor(_ error: Error) -> Bool {
        guard let failure = error as? GatewayFailure else { return false }
        return failure.code == "invalid_request"
    }
}

/// The archived container's one disclosure header: the row that shows how many
/// sessions are archived across every capable server and opens the container.
struct ArchivedSessionsSectionHeader: View {
    let count: Int
    let isExpanded: Bool
    /// True while the expansion's first page is still reading and no row is
    /// shown yet. The leading icon becomes a spinner in its place, so the
    /// header never grows a placeholder row and its layout never moves.
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
            .foregroundStyle(Color.tronEmerald)
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

    /// The header's leading affordance: the archive glyph, or a spinner of the
    /// same size while the first page is still loading.
    @ViewBuilder
    private var leadingIcon: some View {
        if isAwaitingFirstPage {
            ProgressView()
                .controlSize(.small)
                .tint(Color.tronEmerald)
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

/// The archived header's scroll identity, and the one scroll that reveals an
/// expansion.
enum SessionArchiveScrollTarget {
    static let headerID = "archived-sessions-header"
}

extension ScrollViewProxy {
    /// Reveals the archived section the user just expanded. Anchoring the
    /// header's top is exactly the clamp the product asks for and needs no
    /// geometry read: the archived section is always the list's last one, so
    /// with few rows the scroll stops at the content end and the whole section
    /// sits at the bottom, and with many the header reaches the top and the
    /// rows fill the screen. The list clamps the target, so it can never scroll
    /// past the content.
    ///
    /// The revealed rows were published in the same view update, so the scroll
    /// waits one main-actor turn: the list must own the new content before the
    /// offset is resolved, or an early scroll would stop at the old content end
    /// and reveal nothing. The caller supplies the motion, so Reduce Motion is
    /// honored at its owner.
    @MainActor
    func revealArchivedSection(reduceMotion: Bool) {
        Task { @MainActor in
            withAnimation(TronDashboardContentMotion.animation(reduceMotion: reduceMotion)) {
                scrollTo(SessionArchiveScrollTarget.headerID, anchor: .top)
            }
        }
    }
}

/// Rows of one expanded archived container. Rows show their workspace and open
/// the session; the swipe reveals Unarchive and Delete, and each asks for
/// confirmation before it runs. A server whose pages cannot be shown is named
/// inline instead of leaving a silent gap.
struct ArchivedSessionsSectionRows: View {
    let sessions: [SessionSummary]
    let unavailableServerNames: [String]
    let isLoading: Bool
    let hasMore: Bool
    let onOpen: (SessionSummary) -> Void
    let onUnarchive: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void
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

    private func archivedRow(_ session: SessionSummary) -> some View {
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
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
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
