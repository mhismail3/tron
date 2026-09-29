import SwiftUI
import TronMobileCore
import UIKit
import ImageIO

enum KnowledgeDashboardArea: String, CaseIterable, Identifiable {
    case chronicle
    case library
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum KnowledgeDashboardSection: String, CaseIterable, Identifiable {
    case chronicle
    case sources
    case syntheses

    var id: String { rawValue }
    var title: String {
        switch self { case .chronicle: "Chronicle"; case .sources: "Sources"; case .syntheses: "Syntheses" }
    }
    var kind: KnowledgeRecordKind? {
        switch self { case .chronicle: .observation; case .sources: .source; case .syntheses: .note }
    }
}

enum KnowledgeDashboardMenuItem: String, CaseIterable {
    case observationConfiguration = "Observation configuration"
    case needsAttention = "Needs attention"
    case chronicleInfo = "Chronicle info"
    case captureURL = "Capture URL"
    case newNote = "New note"

    var symbol: String {
        switch self {
        case .observationConfiguration: "eye"
        case .needsAttention: "exclamationmark.triangle"
        case .chronicleInfo: "info.circle"
        case .captureURL: "link.badge.plus"
        case .newNote: "note.text.badge.plus"
        }
    }
}

enum KnowledgeDashboardMenuPolicy {
    static func settingsTitle(for area: KnowledgeDashboardArea) -> String {
        "Knowledge settings"
    }

    static func settingsItems(for area: KnowledgeDashboardArea) -> [KnowledgeDashboardMenuItem] {
        [.observationConfiguration, .needsAttention, .chronicleInfo]
    }

    static let creationItems: [KnowledgeDashboardMenuItem] = [.captureURL, .newNote]
}

enum KnowledgeSourceVisibility: String, CaseIterable, Identifiable {
    case saved
    case pending
    case archived

    var id: String { rawValue }
    var title: String {
        switch self { case .saved: "Saved sources"; case .pending: "Pending sources"; case .archived: "Archived sources" }
    }
    /// These flags are only transport visibility requests; admission remains
    /// canonical and `visibleRecords` performs the exact final partition.
    var requestIncludesPending: Bool { self == .pending }
    var requestIncludesArchived: Bool { self == .archived }
}

/// Catalogue pagination is available only for list responses. Search responses
/// are intentionally bounded to one Gateway result page.
enum KnowledgeCatalogRequestPolicy {
    static func includesPending(section: KnowledgeDashboardSection, visibility: KnowledgeSourceVisibility) -> Bool {
        section == .sources && visibility.requestIncludesPending
    }
    static func includesArchived(section: KnowledgeDashboardSection, visibility: KnowledgeSourceVisibility) -> Bool {
        section == .sources && visibility.requestIncludesArchived
    }
    static func sourceAdmission(section: KnowledgeDashboardSection, visibility: KnowledgeSourceVisibility) -> KnowledgeSourceAdmission? {
        guard section == .sources else { return nil }
        switch visibility {
        case .saved: return nil
        case .pending: return .pending
        case .archived: return .archived
        }
    }
}

enum KnowledgeCatalogPaginationPolicy {
    /// Any returned cursor admits a continuation. Library rows paginate search
    /// the same way as the catalogue; a full-record search returns no cursor,
    /// so it stays one bounded page.
    static func admits(cursor: String?, loadingMore: Bool) -> Bool {
        cursor != nil && !loadingMore
    }
}

/// How one changed-row patch lands on the presented page. A patch may only
/// rewrite rows this page already shows; a row it has never seen needs the
/// Gateway's own order, and a changed row that is no longer returned has left
/// the filter.
enum KnowledgeLibraryPatchPolicy {
    enum Outcome: Equatable {
        case patched([KnowledgeSourceRow])
        case requiresFirstPage
    }

    static func outcome(rows: [KnowledgeSourceRow], changedIDs: [String], refreshed: [KnowledgeSourceRow]) -> Outcome {
        guard !refreshed.contains(where: { row in !rows.contains { $0.id == row.id } }) else { return .requiresFirstPage }
        var byID: [String: KnowledgeSourceRow] = [:]
        for row in refreshed { byID[row.id] = row }
        let dropped = Set(changedIDs).subtracting(byID.keys)
        return .patched(rows.compactMap { row -> KnowledgeSourceRow? in
            guard !dropped.contains(row.id) else { return nil }
            return byID[row.id] ?? row
        })
    }
}

/// Library rows load the next page before the end of the list is reached, so
/// scrolling never waits on a button.
enum KnowledgeLibraryPrefetchPolicy {
    static let distance = 5

    static func admits(rows: [KnowledgeSourceRow], cursor: String?, loadingMore: Bool, appearing id: String) -> Bool {
        guard cursor != nil, !loadingMore else { return false }
        return rows.suffix(distance).contains { $0.id == id }
    }
}

enum KnowledgeCatalogPagePolicy {
    static func visibleRecords(_ records: [KnowledgeRecord], in section: KnowledgeDashboardSection, sourceVisibility: KnowledgeSourceVisibility = .saved) -> [KnowledgeRecord] {
        records.filter { record in
            switch section {
            case .syntheses:
                guard case .note(let note) = record.content else { return false }
                return note.role == .synthesis
            case .chronicle: return true
            case .sources:
                guard case .source = record.content else { return false }
                let admission: KnowledgeSourceAdmission? = {
                    guard case .source(let source) = record.content else { return nil }
                    return source.admission?.status
                }()
                switch sourceVisibility {
                case .saved: return admission == .retained || admission == nil
                case .pending: return admission == .pending
                case .archived: return admission == .archived
                }
            }
        }
    }

    static func offersContinuation(nextCursor: String?, loadingMore: Bool) -> Bool {
        nextCursor != nil && !loadingMore
    }
}

struct KnowledgeCatalogRequestKey: Equatable {
    let section: KnowledgeDashboardSection
    let kind: KnowledgeRecordKind?
    let scope: KnowledgeScope?
    let search: String
    let sourceVisibility: KnowledgeSourceVisibility
}

enum KnowledgeCatalogRequestFence {
    static func accepts(_ requested: KnowledgeCatalogRequestKey, current: KnowledgeCatalogRequestKey) -> Bool {
        requested == current
    }
}

extension KnowledgeCatalogRequestKey {
    /// Stable identity of one catalogue filter, used as the first-page cache key.
    var cacheFilterID: String {
        [section.rawValue, kind?.rawValue ?? "all", sourceVisibility.rawValue, scope?.rawValue ?? "all", search].joined(separator: "|")
    }
}

/// Dashboard rhythm. Catalogue rows pack closer than the section rhythm so a
/// long retained list stays scannable; section boundaries add their own inset.
enum KnowledgeDashboardLayout {
    static let recordSpacing: CGFloat = 8
}

/// The presented catalogue page. Library Sources presents Gateway rows, which
/// carry what a row and its header need and nothing more; Chronicle, Syntheses,
/// and observations present full records.
enum KnowledgeCataloguePage {
    case rows([KnowledgeSourceRow], nextCursor: String?, stateRevision: Int)
    case records([KnowledgeRecord], nextCursor: String?, stateRevision: Int)

    var nextCursor: String? {
        switch self { case .rows(_, let cursor, _): cursor; case .records(_, let cursor, _): cursor }
    }
    var stateRevision: Int {
        switch self { case .rows(_, _, let revision): revision; case .records(_, _, let revision): revision }
    }
    var isEmpty: Bool {
        switch self { case .rows(let rows, _, _): rows.isEmpty; case .records(let records, _, _): records.isEmpty }
    }
}

/// Bounded Gateway projection for observations, links, and notes. iOS never
/// mirrors the canonical Knowledge corpus.
struct KnowledgeDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let onSelectDashboard: @MainActor (DashboardMode) -> Void
    let onOpenSettings: @MainActor () -> Void
    let onOpenDraft: @MainActor (KnowledgeRecord) -> Void
    let onOpenSession: @MainActor (String, String) -> Void
    @State private var page: KnowledgeCataloguePage?
    @State private var area: KnowledgeDashboardArea = .chronicle
    @State private var librarySelection: KnowledgeDashboardSection = .sources
    @State private var sourceVisibility: KnowledgeSourceVisibility = .saved
    @State private var chronicleScope: KnowledgeScope?
    @State private var libraryScope: KnowledgeScope?
    @State private var selectedSubject: KnowledgeDetailSubject?
    @State private var selectedIdentity: KnowledgePresentationIdentity?
    @State private var pendingDetailAction: DetailAction?
    private enum DetailAction { case draft(KnowledgeRecord), session(String, String) }
    @State private var search = ""
    /// The query the presented page was asked for. Typing debounces into it so a
    /// word costs one request rather than one per keystroke.
    @State private var effectiveSearch = ""
    @State private var searchDebouncer = KnowledgeSearchDebouncer()
    @State private var loading = false
    @State private var error: String?
    @State private var loadingMore = false
    @State private var coverageStore = KnowledgeCoveragePresentationStore()
    @State private var coverageSheet = false
    @State private var chronicleInfoSheet = false
    @State private var loadGeneration = 0
    @State private var configSheet = false
    @State private var captureSheet = false
    @State private var noteSheet = false
    @State private var showingFilters = false
    @State private var showingSearch = false
    @State private var dashboardHeader = DashboardHeaderState()

    private var section: KnowledgeDashboardSection { area == .chronicle ? .chronicle : librarySelection }
    private var scope: KnowledgeScope? { area == .chronicle ? chronicleScope : libraryScope }
    private var activeSourceVisibility: KnowledgeSourceVisibility { section == .sources ? sourceVisibility : .saved }
    private var requestKind: KnowledgeRecordKind? { section.kind }

    private var filterSummary: String {
        let labels = [section.title,
                      section == .sources ? sourceVisibility.title : nil,
                      section == .chronicle ? (scope?.label ?? "All") : scope?.label]
            .compactMap { $0 }
        return labels.joined(separator: " · ")
    }

    private func requestKey() -> KnowledgeCatalogRequestKey {
        KnowledgeCatalogRequestKey(section: section, kind: requestKind, scope: scope, search: effectiveSearch, sourceVisibility: activeSourceVisibility)
    }

    /// Library Sources need the Gateway's row projection; without it this view
    /// presents the update placeholder instead of a second, slower read path.
    private var supportsLibraryRows: Bool {
        model.gatewayInfo?.capabilities.contains(KnowledgeLibraryCapability.libraryRows) == true
    }
    private var presentsLibraryRows: Bool { section == .sources && supportsLibraryRows }

    var body: some View {
        DashboardChrome(
            mode: .knowledge,
            header: dashboardHeader,
            onSelect: onSelectDashboard,
            actions: dashboardMenuActions,
            showingSearch: showingSearch
        ) {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: KnowledgeDashboardLayout.recordSpacing) {
                        libraryPicker
                        dashboardContent(minimumHeight: max(280, geometry.size.height - 150))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    // The floating controls must never cover the last record or coverage action.
                    .padding(.bottom, 80)
                }
                .tronScrollEdgeChrome()
                .tronDashboardScroll(dashboardHeader)
            }
        } search: {
            TronSearchBar(text: $search, prompt: "Search Knowledge", accent: .tronKnowledge,
                          focusOnAppear: true, onClose: dismissSearch,
                          onFocusChange: { if !$0 { dismissSearch() } })
                .padding(.horizontal, TronSpacing.section)
                .padding(.vertical, 8)
        }
        .font(TronTypography.body)
        .foregroundStyle(Color.tronTextPrimary)
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .tronManagedSheet(item: $selectedSubject, identity: { "knowledge.detail.\($0.id)" }, onDismiss: finishDetailDismissal) { subject in
            KnowledgeDetailSheet(subject: subject, origin: selectedIdentity ?? model.knowledgePresentationIdentity,
                                 onChanged: { await reload() },
                                 onOpenDraft: { stageDetailAction(.draft($0)) },
                                 onOpenSession: { stageDetailAction(.session($0, $1)) })
                .environment(model)
        }
        .onChange(of: area) { _, _ in invalidateCatalogueRequests() }
        .onChange(of: librarySelection) { _, _ in invalidateCatalogueRequests() }
        .onChange(of: sourceVisibility) { _, _ in invalidateCatalogueRequests() }
        .onChange(of: chronicleScope) { _, _ in invalidateCatalogueRequests() }
        .onChange(of: libraryScope) { _, _ in invalidateCatalogueRequests() }
        .onChange(of: search) { _, value in
            // Retire any in-flight read for the previous query at once; the
            // debounced query starts the next one.
            loadGeneration &+= 1
            loadingMore = false
            scheduleSearch(value)
        }
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in
            // Retire both the visible page and any manually spawned page task;
            // the next task must carry the new Gateway identity from its start.
            loadGeneration += 1
            loadingMore = false
            coverageStore.reset()
            coverageSheet = false
            page = nil; selectedSubject = nil; selectedIdentity = nil; pendingDetailAction = nil
            error = nil
            model.knowledgePreviews.removeAll()
        }
        // A committed Knowledge mutation refreshes only what changed. The
        // covered page keeps its rows and scroll position unless the Gateway
        // says this page is behind.
        .onChange(of: model.knowledgeInvalidationRevision) { _, _ in applyKnowledgeChange() }
        .onChange(of: model.connectionState) { _, state in
            if state == .connected { model.knowledgePreviews.retryUnavailable() }
        }
        .tronManagedSheet(isPresented: $coverageSheet, identity: "knowledge.coverage", onDismiss: finishDetailDismissal) {
            coverageDetailSheet
        }
        .tronManagedSheet(isPresented: $chronicleInfoSheet, identity: "knowledge.chronicle-info") {
            chronicleInfoSheetView
        }
        .tronManagedSheet(isPresented: $showingFilters, identity: "knowledge.filters") {
            knowledgeFilterSheet
        }
        .tronManagedSheet(isPresented: $configSheet, identity: "knowledge.configuration") {
            KnowledgeConfigurationView().environment(model)
        }
        .tronManagedSheet(isPresented: $captureSheet, identity: "knowledge.capture") {
            KnowledgeCaptureView { captureSheet = false; await reload() }.environment(model)
        }
        .tronManagedSheet(isPresented: $noteSheet, identity: "knowledge.note") {
            KnowledgeNoteCreateView { noteSheet = false; await reload() }.environment(model)
        }
        .task(id: "\(section.rawValue)/\(activeSourceVisibility.rawValue)/\(scope?.rawValue ?? "all")/\(effectiveSearch)/\(activity.allowsPresentationPublication)/\(model.knowledgePresentationIdentity.profileID ?? "none")/\(model.knowledgePresentationIdentity.lifecycleGeneration ?? -1)/\(model.knowledgePresentationIdentity.connectionID ?? -1)") {
            guard activity.allowsPresentationPublication else { return }
            await reload()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            if !active {
                // Covered reads are disposable, but their accepted page remains
                // the dashboard projection until a matching refresh arrives.
                loadGeneration &+= 1
                loadingMore = false
                coverageStore.suspend()
            }
        }
        .onDisappear { coverageStore.suspend(); searchDebouncer.cancel() }
    }

    private var dashboardMenuActions: DashboardMenuActions {
        let perform: (KnowledgeDashboardMenuItem) -> @MainActor () -> Void = { item in
            { [self] in
                switch item {
                case .observationConfiguration: configSheet = true
                case .needsAttention: openCoverageDetail()
                case .chronicleInfo: chronicleInfoSheet = true
                case .captureURL: captureSheet = true
                case .newNote: noteSheet = true
                }
            }
        }
        let settingsActions = KnowledgeDashboardMenuPolicy.settingsItems(for: area).map {
            DashboardMenuAction(title: $0.rawValue, symbol: $0.symbol, perform: perform($0))
        }
        let creationActions = KnowledgeDashboardMenuPolicy.creationItems.map {
            DashboardMenuAction(title: $0.rawValue, symbol: $0.symbol, perform: perform($0))
        }
        return DashboardMenuActions(
            search: { showingSearch = true },
            filter: { showingFilters = true },
            settings: onOpenSettings,
            settingsMenu: .init(title: KnowledgeDashboardMenuPolicy.settingsTitle(for: area), symbol: "slider.horizontal.3", actions: settingsActions),
            creation: creationActions
        )
    }

    private func selectSection(_ value: KnowledgeDashboardSection) {
        guard value != .chronicle else { area = .chronicle; return }
        librarySelection = value
        area = .library
    }

    private func setActiveScope(_ value: KnowledgeScope?) {
        if area == .chronicle { chronicleScope = value } else { libraryScope = value }
    }

    private func dismissSearch() {
        searchDebouncer.cancel()
        search = ""
        effectiveSearch = ""
        showingSearch = false
    }

    /// One request per settled query instead of one per keystroke; a short query
    /// is presented as no query rather than as an empty result page.
    private func scheduleSearch(_ value: String) {
        searchDebouncer.schedule(value) { next in
            guard next != effectiveSearch else { return }
            effectiveSearch = next
        }
    }

    private var libraryPicker: some View {
        TronSegmentedControl(
            options: [(label: "Chronicle", value: KnowledgeDashboardArea.chronicle),
                      (label: "Library", value: KnowledgeDashboardArea.library)],
            selection: $area,
            accent: .tronKnowledge,
            foreground: .tronKnowledgeText,
            minimumHeight: 40
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Knowledge area")
        .padding(.top, TronSpacing.sm)
    }

    @ViewBuilder
    private func dashboardContent(minimumHeight: CGFloat) -> some View {
        if section == .sources, !supportsLibraryRows {
            TronPlaceholderState(title: "Update the Gateway to browse the library",
                                 detail: "This Gateway does not serve the library's compact rows yet. Update it on your Mac, then reopen this tab.",
                                 icon: "arrow.down.circle", accent: .tronKnowledge)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
        } else if loading && page == nil {
            TronLoadingState(label: "Loading Knowledge…", accent: .tronKnowledge)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
        } else if page == nil, let error {
            TronPlaceholderState(title: "Knowledge unavailable", detail: error,
                                 icon: "externaldrive.badge.xmark", accent: .tronKnowledge,
                                 actionTitle: "Retry", action: { Task { await reload() } })
                .frame(minHeight: minimumHeight)
        } else if page?.isEmpty != false {
            let filtered = scope != nil || !effectiveSearch.isEmpty || section != .chronicle || sourceVisibility != .saved
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                TronPlaceholderState(title: filtered ? "No matching Knowledge" : "No Knowledge yet",
                                     detail: filtered ? "Adjust your search or filters to see more records." : "Observations, links, and notes retained by this Gateway will appear here.",
                                     icon: filtered ? "line.3.horizontal.decrease.circle" : "book.closed", accent: .tronKnowledge)
                    .frame(minHeight: minimumHeight)
                if KnowledgeCatalogPagePolicy.offersContinuation(nextCursor: page?.nextCursor, loadingMore: loadingMore) {
                    loadMoreButton
                }
            }
        } else {
            // The catalogue header opens a new section, so it keeps the section
            // rhythm while the rows themselves pack tighter.
            Text(filterSummary).font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronKnowledge)
                .padding(.top, TronSpacing.md)
            if let error {
                TronSettingsNotice(message: "Refresh unavailable: \(error)", accent: .tronAmber)
            }
            presentedRows
        }
    }

    @ViewBuilder
    private var presentedRows: some View {
        let previewIdentity = model.knowledgePresentationIdentity
        switch page {
        case .rows(let rows, _, _):
            ForEach(rows) { row in
                Button {
                    selectedSubject = .row(row)
                    selectedIdentity = previewIdentity
                } label: {
                    KnowledgeSourceRowView(row: row, previews: model.knowledgePreviews)
                }
                .buttonStyle(.plain)
                .onAppear { prefetchIfNeeded(row) }
            }
            if KnowledgeCatalogPagePolicy.offersContinuation(nextCursor: page?.nextCursor, loadingMore: loadingMore) {
                loadMoreButton
            }
        case .records(let records, _, _):
            ForEach(records) { record in
                Button {
                    selectedSubject = .record(record)
                    selectedIdentity = previewIdentity
                } label: { KnowledgeRecordRow(record: record) }
                    .buttonStyle(.plain)
            }
            if KnowledgeCatalogPagePolicy.offersContinuation(nextCursor: page?.nextCursor, loadingMore: loadingMore) {
                loadMoreButton
            }
        case nil:
            EmptyView()
        }
    }

    private var loadMoreButton: some View {
        TronPaginationButton(label: "Load more", loadingLabel: "Loading…", icon: "arrow.down", isLoading: loadingMore, accent: .tronKnowledge, action: loadMore)
            .frame(maxWidth: .infinity)
            .padding(.top, TronSpacing.md)
    }

    private var knowledgeFilterSheet: some View {
        TronDashboardFilterSheet(title: area == .chronicle ? "Chronicle filters" : "Library filters", accent: .tronKnowledge,
                                 detents: [.medium, .large], onDone: { showingFilters = false }) {
            if area == .library {
                TronDashboardFilterSectionTitle(title: "Library view", detail: "Choose one library collection at a time.")
                TronDashboardFilterOption(title: "Sources", selected: section == .sources, accent: .tronKnowledge,
                                          inactiveAccent: .tronSlate) { selectSection(.sources) }
                TronDashboardFilterOption(title: "Syntheses", selected: section == .syntheses, accent: .tronKnowledge,
                                          inactiveAccent: .tronSlate) { selectSection(.syntheses) }
                if section == .sources {
                    TronDashboardFilterSectionTitle(title: "Source visibility", detail: "Choose the saved, waiting, or archived sources you want to browse.")
                    ForEach(KnowledgeSourceVisibility.allCases) { value in
                        TronDashboardFilterOption(title: value.title, selected: sourceVisibility == value, accent: .tronKnowledge,
                                                  inactiveAccent: .tronSlate) { sourceVisibility = value }
                    }
                }
            }
            TronDashboardFilterSectionTitle(title: "Scope", detail: "Narrow this dashboard without changing the collection.")
            TronDashboardFilterOption(title: "All scopes", selected: scope == nil, accent: .tronKnowledge,
                                      inactiveAccent: .tronSlate) { setActiveScope(nil) }
            ForEach(KnowledgeScope.allCases, id: \.self) { value in
                TronDashboardFilterOption(title: value.label, selected: scope == value, accent: .tronKnowledge,
                                          inactiveAccent: .tronSlate) { setActiveScope(value) }
            }
        }
    }
    private var chronicleInfoSheetView: some View {
        KnowledgeChronicleInfoSheet()
            .environment(model)
    }

    /// The coverage list lives in its own detail sheet so the dashboard card
    /// stays an informational overview.
    private var coverageDetailSheet: some View {
        KnowledgeCoverageSheetHost(
            identity: model.knowledgePresentationIdentity,
            store: coverageStore,
            onOpenSession: { cut in stageCoverageNavigation(.session(cut.range.sessionId, cut.range.fromEntryId)) }
        )
        .environment(model)
    }

    private func invalidateCatalogueRequests() {
        loadGeneration &+= 1
        loadingMore = false
    }

    /// How a completed read is published. `mergeFirstPage` keeps the deeper
    /// rows a reader already reached and never shows a loading state, so a
    /// Gateway change refreshes content without clearing the screen.
    private enum KnowledgeCatalogueRefresh { case replace, mergeFirstPage }

    private func reload(_ refresh: KnowledgeCatalogueRefresh = .replace) async {
        loadGeneration += 1; let generation = loadGeneration; let identity = model.knowledgePresentationIdentity
        let requestedSection = section
        let requestedKind = requestKind
        let requestedScope = scope
        let requestedQuery = effectiveSearch
        let requestedVisibility = activeSourceVisibility
        let requestedKey = KnowledgeCatalogRequestKey(section: requestedSection, kind: requestedKind, scope: requestedScope, search: requestedQuery, sourceVisibility: requestedVisibility)
        guard activity.allowsPresentationPublication, identity.profileID != nil, identity.lifecycleGeneration != nil else { return }
        if requestedSection == .sources, !supportsLibraryRows { page = nil; error = nil; loading = false; return }
        if refresh == .replace { loading = true; error = nil }
        defer { if generation == loadGeneration { loading = false } }
        // A cached first page appears immediately; the Gateway's page replaces it
        // as soon as it arrives, so no spinner is shown over known content.
        if refresh == .replace, page == nil, requestedQuery.isEmpty, let profileID = identity.profileID,
           let cached = await model.knowledgeLibraryCache.page(profileID: profileID, filterID: requestedKey.cacheFilterID) {
            guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            page = .rows(cached.rows, nextCursor: cached.nextCursor, stateRevision: cached.stateRevision)
        }
        do {
            var acceptedRows: KnowledgeSourceRowPage?
            var acceptedRecords: KnowledgeListResponse?
            if requestedSection == .sources {
                let response = requestedQuery.isEmpty
                    ? try await model.knowledge.sourceRows(scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), limit: 50)
                    : try await model.knowledge.searchSourceRows(query: requestedQuery, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), limit: 50)
                acceptedRows = response
            } else if requestedQuery.isEmpty {
                acceptedRecords = try await model.knowledge.list(kind: requestedKind, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), limit: 50)
            } else {
                let found = try await model.knowledge.search(query: requestedQuery, kind: requestedKind, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), limit: 50)
                acceptedRecords = KnowledgeListResponse(records: found.hits.map { $0.record }, nextCursor: nil, stateRevision: found.stateRevision)
            }
            guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                  activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            if let acceptedRows {
                publish(rows: acceptedRows.rows, nextCursor: acceptedRows.nextCursor, stateRevision: acceptedRows.stateRevision, refresh: refresh)
                if requestedQuery.isEmpty, refresh == .replace, case .rows(let rows, let cursor, let revision) = page,
                   let profileID = identity.profileID {
                    await model.knowledgeLibraryCache.save(profileID: profileID, filterID: requestedKey.cacheFilterID,
                                                           page: KnowledgeLibraryCachedPage(rows: rows, nextCursor: cursor, stateRevision: revision))
                }
            } else if let acceptedRecords {
                let visible = KnowledgeCatalogPagePolicy.visibleRecords(acceptedRecords.records, in: requestedSection, sourceVisibility: requestedVisibility)
                publish(records: visible, nextCursor: acceptedRecords.nextCursor, stateRevision: acceptedRecords.stateRevision, refresh: refresh)
            }
        } catch is CancellationError { return } catch {
            // Gateway cancellation can be wrapped as a possibly-sent failure
            // after the sheet retires. Task cancellation and the generation
            // fence own that disposable read; neither may become dashboard UI.
            guard !Task.isCancelled, generation == loadGeneration,
                  KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                  activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == identity else { return }
            self.error = error.localizedDescription
        }
    }

    private func publish(rows: [KnowledgeSourceRow], nextCursor: String?, stateRevision: Int, refresh: KnowledgeCatalogueRefresh) {
        guard refresh == .mergeFirstPage, case .rows(let current, let cursor, let revision) = page else {
            page = .rows(rows, nextCursor: nextCursor, stateRevision: stateRevision); return
        }
        // The fresh first page is authoritative for order and content; rows the
        // reader already paged to keep their place after it.
        let freshIDs = Set(rows.map(\.id))
        let tail = current.filter { !freshIDs.contains($0.id) }
        page = .rows(rows + tail, nextCursor: cursor ?? nextCursor, stateRevision: max(revision, stateRevision))
    }

    private func publish(records: [KnowledgeRecord], nextCursor: String?, stateRevision: Int, refresh: KnowledgeCatalogueRefresh) {
        guard refresh == .mergeFirstPage, case .records(let current, let cursor, let revision) = page else {
            page = .records(records, nextCursor: nextCursor, stateRevision: stateRevision); return
        }
        let freshIDs = Set(records.map(\.id))
        let tail = current.filter { !freshIDs.contains($0.id) }
        page = .records(records + tail, nextCursor: cursor ?? nextCursor, stateRevision: max(revision, stateRevision))
    }

    /// A committed mutation refreshes the presented page. Rows the Gateway named
    /// are patched in place; anything else refreshes the first page and merges
    /// without clearing the screen or the reader's position.
    private func applyKnowledgeChange() {
        guard let current = page else { return }
        guard let change = model.latestKnowledgeChange else {
            Task { await reload(.mergeFirstPage) }; return
        }
        guard KnowledgeChangeGating.requiresRefresh(eventRevision: change.stateRevision, pageRevision: current.stateRevision) else { return }
        guard case .rows = current, presentsLibraryRows, effectiveSearch.isEmpty, let ids = change.recordIds else {
            Task { await reload(.mergeFirstPage) }; return
        }
        Task { await patchRows(ids: ids) }
    }

    private func patchRows(ids: [String]) async {
        guard case .rows(let rows, let cursor, let revision) = page, presentsLibraryRows, effectiveSearch.isEmpty else { return }
        let identity = model.knowledgePresentationIdentity
        let requestedKey = requestKey()
        guard activity.allowsPresentationPublication else { return }
        do {
            let refreshed = try await model.knowledge.sourceRows(ids: ids, scope: scope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: section, visibility: activeSourceVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: section, visibility: activeSourceVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: section, visibility: activeSourceVisibility))
            guard !Task.isCancelled, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity,
                  KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()) else { return }
            guard case .patched(let patched) = KnowledgeLibraryPatchPolicy.outcome(rows: rows, changedIDs: ids, refreshed: refreshed.rows) else {
                // A row this page has never seen belongs in canonical order, so
                // the first page is refetched rather than guessed at.
                await reload(.mergeFirstPage); return
            }
            // The Gateway answered at the revision it named, so this page has
            // now seen that revision.
            page = .rows(patched, nextCursor: cursor, stateRevision: max(revision, refreshed.stateRevision))
        } catch {
            // A failed patch is repaired by the next change or an explicit
            // refresh; it must not become an error banner over a usable page.
        }
    }

    private func prefetchIfNeeded(_ row: KnowledgeSourceRow) {
        guard case .rows(let rows, let cursor, _) = page else { return }
        guard KnowledgeLibraryPrefetchPolicy.admits(rows: rows, cursor: cursor, loadingMore: loadingMore, appearing: row.id) else { return }
        loadMore()
    }

    private func loadMore() {
        guard let current = page, KnowledgeCatalogPaginationPolicy.admits(cursor: current.nextCursor, loadingMore: loadingMore), let cursor = current.nextCursor else { return }
        loadingMore = true
        let generation = loadGeneration
        let requestedQuery = effectiveSearch
        let requestedKind = requestKind ?? section.kind
        let requestedScope = scope
        let requestedSection = section
        let requestedVisibility = activeSourceVisibility
        let requestedKey = KnowledgeCatalogRequestKey(section: requestedSection, kind: requestedKind, scope: requestedScope, search: requestedQuery, sourceVisibility: requestedVisibility)
        let identity = model.knowledgePresentationIdentity
        Task { @MainActor in
            defer { if generation == loadGeneration { loadingMore = false } }
            guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                  activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            do {
                if requestedSection == .sources {
                    let nextPage = requestedQuery.isEmpty
                        ? try await model.knowledge.sourceRows(scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), cursor: cursor, limit: 50)
                        : try await model.knowledge.searchSourceRows(query: requestedQuery, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), cursor: cursor, limit: 50)
                    guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                          activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity,
                          nextPage.nextCursor != cursor, case .rows(let rows, _, let revision) = self.page else { return }
                    let known = Set(rows.map(\.id))
                    self.page = .rows(rows + nextPage.rows.filter { !known.contains($0.id) }, nextCursor: nextPage.nextCursor, stateRevision: max(revision, nextPage.stateRevision))
                    return
                }
                let nextPage = try await model.knowledge.list(kind: requestedKind, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), cursor: cursor, limit: 50)
                let visiblePage = KnowledgeListResponse(records: KnowledgeCatalogPagePolicy.visibleRecords(nextPage.records, in: requestedSection, sourceVisibility: requestedVisibility), nextCursor: nextPage.nextCursor, stateRevision: nextPage.stateRevision)
                guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                      activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity,
                      visiblePage.nextCursor != cursor, case .records(let records, _, let revision) = self.page else { return }
                // A Gateway page may contain only another visibility class (or
                // records already admitted by a retried page). Advance the
                // canonical cursor even when this projection adds no rows;
                // rejecting that page made Archived appear empty with an inert
                // continuation button.
                let known = Set(records.map(\.id))
                self.page = .records(records + visiblePage.records.filter { !known.contains($0.id) }, nextCursor: visiblePage.nextCursor, stateRevision: max(revision, visiblePage.stateRevision))
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == loadGeneration,
                      KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                      activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == identity else { return }
                // A cursor from an older state revision is stale, not fatal:
                // restart the first page instead of stranding the reader.
                if let failure = error as? GatewayFailure, failure.code == "conflict" { await reload(); return }
                self.error = error.localizedDescription
            }
        }
    }

    private func stageDetailAction(_ action: DetailAction) {
        guard model.knowledgePresentationIdentity == selectedIdentity, pendingDetailAction == nil else { return }
        // The existing session/new-session owner must not present through an
        // observation sheet that is still dismissing.
        pendingDetailAction = action
        selectedSubject = nil
    }

    /// The coverage sheet belongs to the dashboard rather than to one record.
    /// It captures the presented identity here so a Gateway switch while it
    /// dismisses cannot navigate a stale citation.
    private func openCoverageDetail() {
        selectedIdentity = model.knowledgePresentationIdentity
        coverageSheet = true
    }

    private func stageCoverageNavigation(_ action: DetailAction) {
        guard model.knowledgePresentationIdentity == selectedIdentity, pendingDetailAction == nil else { return }
        pendingDetailAction = action
        coverageSheet = false
    }

    /// Both detail sheets hand navigation off only after they dismiss, because
    /// the session owner must not present through a sheet that is still going
    /// away.
    private func finishDetailDismissal() {
        let action = pendingDetailAction
        pendingDetailAction = nil
        defer { selectedIdentity = nil }
        guard model.knowledgePresentationIdentity == selectedIdentity else { return }
        switch action {
        case .draft(let record): onOpenDraft(record)
        case .session(let sessionID, let entryID): onOpenSession(sessionID, entryID)
        case nil: break
        }
    }
}

private struct KnowledgeChronicleInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @State private var status: KnowledgeStatus?
    @State private var error: String?
    @State private var requestGeneration = 0
    @State private var detent: PresentationDetent = .medium

    private var identity: KnowledgePresentationIdentity { model.knowledgePresentationIdentity }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    if let status {
                        TronMetadataTable(title: "Observation coverage", accent: .tronKnowledge, rows: [
                            metadataRow("Observed", status.coverage.observedCount),
                            metadataRow("Empty", status.coverage.emptyCount),
                            metadataRow("Excluded", status.coverage.excludedCount),
                            metadataRow("Pending", status.coverage.pendingCount),
                            metadataRow("Failed", status.coverage.failedCount),
                            metadataRow("Unavailable", status.coverage.unavailableCount),
                        ])
                        Text("Settled \(status.coverage.observedCount + status.coverage.emptyCount + status.coverage.excludedCount) · \(status.coverage.remainingCount) need attention")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextSecondary)
                    } else if let error {
                        TronPlaceholderState(title: "Chronicle info unavailable", detail: error, icon: "externaldrive.badge.xmark", accent: .tronKnowledge,
                                             actionTitle: "Retry", action: { requestGeneration &+= 1 })
                    } else {
                        TronLoadingState(label: "Loading Chronicle info…", accent: .tronKnowledge)
                    }
                }
                .padding(TronSpacing.section)
            }
            .tronNavigationTitle("Chronicle info", accent: .tronKnowledge)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronKnowledge)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .tronPresentation()
        .task(id: "\(requestGeneration)/\(activity.allowsPresentationPublication)/\(identity.profileID ?? "none")/\(identity.lifecycleGeneration ?? -1)/\(identity.connectionID ?? -1)") {
            await load()
        }
        .onChange(of: identity) { _, _ in
            status = nil
            error = nil
            requestGeneration &+= 1
        }
    }

    @Environment(\.dismiss) private var dismiss

    private func metadataRow(_ title: String, _ value: Int) -> TronMetadataTableRow {
        TronMetadataTableRow(id: title, title: title, value: value.formatted(.number))
    }

    @MainActor private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let requestIdentity = identity
        let generation = requestGeneration
        do {
            let value = try await model.knowledge.status()
            guard !Task.isCancelled, generation == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
            status = value
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct KnowledgeCoverageSheetHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let identity: KnowledgePresentationIdentity
    let store: KnowledgeCoveragePresentationStore
    let onOpenSession: (KnowledgeObservationCoverage) -> Void
    @State private var status: KnowledgeStatus?
    @State private var statusError: String?
    @State private var requestGeneration = 0
    @State private var mutationError: String?
    @State private var clearingID: String?
    @State private var detent: PresentationDetent = .medium
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let status {
                    KnowledgeCoverageDetailSheet(
                        coverage: status.coverage,
                        cuts: store.cuts,
                        showsInitialLoading: store.showsInitialLoading,
                        loadingMore: store.loading,
                        canLoadMore: store.nextCursor != nil,
                        errorText: store.error,
                        mutationErrorText: mutationError,
                        clearingCutID: clearingID,
                        allowsActions: activity.allowsPresentationPublication,
                        onOpenSession: onOpenSession,
                        onClear: { clear($0) },
                        onLoadMore: { loadMore() }
                    )
                } else if let statusError {
                    TronPlaceholderState(title: "Needs attention unavailable", detail: statusError,
                                         icon: "externaldrive.badge.xmark", accent: .tronKnowledge,
                                         actionTitle: "Retry", action: { requestGeneration &+= 1 })
                } else {
                    TronLoadingState(label: "Loading attention…", accent: .tronKnowledge)
                }
            }
            .tronNavigationTitle("Observation coverage", accent: .tronKnowledge)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronKnowledge)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .tronPresentation()
        .task(id: "\(requestGeneration)/\(activity.allowsPresentationPublication)/\(identity.profileID ?? "none")/\(identity.lifecycleGeneration ?? -1)/\(identity.connectionID ?? -1)") {
            await load()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            if !active { store.suspend() }
        }
        .onDisappear { store.suspend() }
        .onChange(of: identity) { _, _ in
            status = nil
            statusError = nil
            requestGeneration &+= 1
            store.reset()
        }
    }

    @MainActor private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let requestIdentity = identity
        let generation = requestGeneration
        do {
            let value = try await model.knowledge.status()
            guard !Task.isCancelled, generation == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
            status = value
            statusError = nil
            guard model.gatewayInfo?.capabilities.contains(KnowledgeRPCClient.coverageFilterCapability) == true else {
                store.reset()
                return
            }
            await store.load(identity: requestIdentity, expectedStateRevision: value.stateRevision ?? 0,
                             request: { cursor in
                                 try await model.knowledge.coverage(cursor: cursor, limit: 100,
                                     dispositions: KnowledgeCoveragePresentationPolicy.attentionDispositions)
                             },
                             isCurrent: { !Task.isCancelled && generation == requestGeneration && activity.allowsPresentationPublication && model.knowledgePresentationIdentity == requestIdentity })
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
            statusError = error.localizedDescription
        }
    }

    @MainActor private func loadMore() {
        let requestIdentity = identity
        Task { @MainActor in
            await store.loadMore(identity: requestIdentity,
                                 request: { cursor in
                                     try await model.knowledge.coverage(cursor: cursor, limit: 100,
                                         dispositions: KnowledgeCoveragePresentationPolicy.attentionDispositions)
                                 },
                                 isCurrent: { !Task.isCancelled && activity.allowsPresentationPublication && model.knowledgePresentationIdentity == requestIdentity })
        }
    }

    @MainActor private func clear(_ cut: KnowledgeObservationCoverage) {
        guard activity.allowsPresentationPublication, clearingID == nil else { return }
        let requestIdentity = identity
        clearingID = cut.id
        mutationError = nil
        Task { @MainActor in
            defer { if model.knowledgePresentationIdentity == requestIdentity { clearingID = nil } }
            do {
                _ = try await model.knowledge.dismissCoverage(cut, capabilities: model.gatewayInfo?.capabilities ?? [])
                guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }
                requestGeneration &+= 1
            } catch is CancellationError {
                return
            } catch {
                guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }
                mutationError = error.localizedDescription
            }
        }
    }
}

/// The catalogue row for one retained record. Dense by design: several of these
/// should fit on a phone screen, so the row keeps one type step below the
/// detail sheet and only the statement's leading lines.
/// The catalogue row for an observation or a note. Library Sources present
/// `KnowledgeSourceRowView` from the Gateway's rows instead, so a record row is
/// never asked to render a source.
struct KnowledgeRecordRow: View {
    let record: KnowledgeRecord

    var body: some View {
        Group {
            if let observation = KnowledgeObservationPresentation(record: record) {
                KnowledgeObservationStatement(presentation: observation, preview: true)
                    .accessibilityElement(children: .combine)
            } else {
                otherRecord
            }
        }
        .padding(.horizontal, TronSpacing.xl)
        .padding(.vertical, TronSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronScrollSurface(accent: .tronKnowledge, tintOpacity: 0.08)
        .contentShape(Rectangle())
    }

    private var otherRecord: some View {
        HStack(alignment: .top, spacing: TronSpacing.lg) {
            Image(systemName: record.kind.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronKnowledge)
                .frame(width: TronSettingsLayoutPolicy.iconSize, height: TronSettingsLayoutPolicy.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text(record.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.summary)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(record.kind.label) · \(record.scope.label) · \(record.updatedAt)")
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: TronSpacing.md)
            Image(systemName: "chevron.right")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronKnowledge)
                .accessibilityHidden(true)
        }
    }
}

struct KnowledgeSourceThumbnail: View {
    let letters: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color.tronKnowledge.opacity(0.16))
            Text(letters)
                .font(TronTypography.sans(size: size * 0.25, weight: .bold))
                .foregroundStyle(Color.tronKnowledge)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One Library Sources row, presented from the Gateway's row projection. It
/// keeps the compact catalogue shape — two title lines and one domain/type line
/// beside a preview centered on that block — and asks the preview store for its
/// image, so a row that scrolls away and back never refetches.
struct KnowledgeSourceRowView: View {
    let row: KnowledgeSourceRow
    let previews: KnowledgePreviewStore
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment
    /// Two title lines plus one subtext line; the preview matches that block so
    /// every row has the same compact height and centers its text beside it.
    private static let previewSize: CGFloat = 52

    var body: some View {
        HStack(alignment: .center, spacing: TronSpacing.lg) {
            if let image = previews.image(for: row.preview?.hash) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: Self.previewSize, height: Self.previewSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Preview for \(row.title)")
            } else {
                KnowledgeSourceThumbnail(letters: KnowledgeSourceRowPresentationPolicy.thumbnailLetters(row), size: Self.previewSize)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(2)
                Text(KnowledgeSourceRowPresentationPolicy.subtitle(row))
                    .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens entry details")
        .task(id: "\(row.id):\(row.revisionId):\(row.preview?.hash ?? "none")") {
            guard let request = row.previewRequest else { return }
            _ = await previews.load(request, includeArchived: row.admission == .archived)
        }
    }
}

/// One entry's header: the title, a pill naming the original link, and a square
/// preview that spans exactly the title-plus-pill block. The Library row and the
/// loaded detail share it, so an entry opened from a row does not change shape
/// when its full record arrives.
struct KnowledgeEntryHeader: View {
    let title: String
    let linkLabel: String?
    let linkURL: URL?
    let preview: UIImage?
    let thumbnailLetters: String
    let onOpenLink: (URL) -> Void
    @State private var textHeight: CGFloat = 44

    var body: some View {
        // The preview's top meets the title's first line and its bottom meets the
        // visible pill capsule.
        let side = min(max(textHeight, 44), 120)
        HStack(alignment: .top, spacing: TronSpacing.lg) {
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    KnowledgeSourceThumbnail(letters: thumbnailLetters, size: side)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // The pill names the destination, so the domain is not repeated
                // as a separate caption. The original link is the source of truth.
                if let linkURL {
                    Button { onOpenLink(linkURL) } label: {
                        TronInlineActionLabel(linkLabel ?? linkURL.host ?? "Open original", icon: "arrow.up.right", accent: .tronKnowledge)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    // Lay out the visible capsule, not its taller transparent
                    // hit target; the 44-point target still overhangs into padding.
                    .padding(.vertical, -(TronSettingsLayoutPolicy.compactPillTargetHeight - TronSettingsLayoutPolicy.compactPillHeight) / 2)
                    .accessibilityLabel("Open original")
                    .accessibilityHint("Opens the page in the in-app browser")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
        }
        .padding(TronSettingsLayoutPolicy.rowHorizontalPadding)
        .tronGlassSurface(accent: .tronKnowledge, tintOpacity: 0.06)
    }
}

/// An entry opened from its Library row. The row's header is presented at once
/// and the full record replaces it when it arrives, so the tap is never a blank
/// sheet; every behavior after that is the record-based detail's.
struct KnowledgeEntryLoadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let row: KnowledgeSourceRow
    let origin: KnowledgePresentationIdentity
    let onChanged: () async -> Void
    let onOpenDraft: (KnowledgeRecord) -> Void
    let onOpenSession: (String, String) -> Void
    @State private var record: KnowledgeRecord?
    @State private var error: String?
    @State private var requestGeneration = 0
    @State private var externalPageURL: URL?

    var body: some View {
        Group {
            if let record {
                KnowledgeDetailView(record: record, origin: origin, onChanged: onChanged,
                                    onOpenDraft: onOpenDraft, onOpenSession: onOpenSession)
            } else {
                loadingBody
            }
        }
        .task(id: "entry-\(row.id):\(row.revisionId):\(origin.profileID ?? "none"):\(origin.lifecycleGeneration ?? -1):\(origin.connectionID ?? -1):\(requestGeneration)") {
            await load()
        }
    }

    @ViewBuilder private var loadingBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                KnowledgeEntryHeader(
                    title: row.title,
                    linkLabel: KnowledgeSourceRowPresentationPolicy.domain(row),
                    linkURL: KnowledgeSourceRowPresentationPolicy.originalURL(row),
                    preview: model.knowledgePreviews.image(for: row.preview?.hash),
                    thumbnailLetters: KnowledgeSourceRowPresentationPolicy.thumbnailLetters(row),
                    onOpenLink: { externalPageURL = $0 }
                )
                if let summary = row.summary {
                    // The row already carries the current summary, so the entry
                    // never flashes a generate action it is about to replace.
                    TronSettingsGroup("Summary", accent: .tronKnowledge) {
                        Text(summary)
                            .font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(TronSettingsLayoutPolicy.rowHorizontalPadding)
                    }
                }
                if let error {
                    TronPlaceholderState(title: "Entry unavailable", detail: error,
                                         icon: "externaldrive.badge.xmark", accent: .tronKnowledge,
                                         actionTitle: "Retry", action: { requestGeneration &+= 1 })
                } else {
                    TronLoadingState(label: "Loading entry…", accent: .tronKnowledge)
                }
            }
            .padding(.horizontal, TronSpacing.xlarge)
            .padding(.vertical, TronSpacing.large)
        }
        .tronScrollEdgeChrome()
        .tronSettingsLayout()
        .tronNavigationTitle("Entry Detail", accent: .tronKnowledge)
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .tronManagedSheet(isPresented: Binding(get: { externalPageURL != nil }, set: { if !$0 { externalPageURL = nil } }), identity: "knowledge.external.\(row.id)") {
            if let externalPageURL {
                TronSafariView(url: externalPageURL)
                    .ignoresSafeArea(.container, edges: .all)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
        }
    }

    private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let generation = requestGeneration
        let requestedIdentity = model.knowledgePresentationIdentity
        do {
            // The row names the exact revision it presented, and its admission
            // carries the authority an archived or pending record needs.
            let value = try await model.knowledge.read(id: row.id, revisionID: row.revisionId,
                                                       includeArchived: row.admission == .archived,
                                                       includePending: row.admission == .pending)
            guard !Task.isCancelled, generation == requestGeneration, activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestedIdentity else { return }
            guard let value else { error = "This entry is no longer available."; return }
            record = value
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration, activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestedIdentity else { return }
            self.error = error.localizedDescription
        }
    }
}

struct KnowledgeDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let origin: KnowledgePresentationIdentity
    let onChanged: () async -> Void
    let onOpenDraft: (KnowledgeRecord) -> Void
    let onOpenSession: (String, String) -> Void
    @State private var currentRecord: KnowledgeRecord
    @State private var mutationInFlight = false
    @State private var noteBody = ""
    private let navigationAncestors: Set<String>

    init(record: KnowledgeRecord, origin: KnowledgePresentationIdentity, onChanged: @escaping () async -> Void, onOpenDraft: @escaping (KnowledgeRecord) -> Void, onOpenSession: @escaping (String, String) -> Void, navigationAncestors: Set<String> = []) {
        self.navigationAncestors = navigationAncestors.union([record.id])
        self.origin = origin
        self.onChanged = onChanged
        self.onOpenDraft = onOpenDraft
        self.onOpenSession = onOpenSession
        _currentRecord = State(initialValue: record)
    }
    @State private var editing = false
    @State private var message: String?
    @State private var forgetConfirmation = false
    @State private var correctionSheet = false
    @State private var technicalDetailsSheet = false
    @State private var evidenceMessage: String?
    @State private var reflectedHandoff: KnowledgeRecord?
    @State private var reflectionRequestGeneration = 0
    @State private var linkedReader = KnowledgeLinkedRecordReaderStore()
    @State private var citationTitles: [String: String] = [:]
    @State private var externalPageURL: URL?
    private var admitsOrigin: Bool { model.knowledgePresentationIdentity == origin && activity.allowsPresentationPublication }
    /// The preview is content-addressed and shared with the catalogue row the
    /// entry was opened from, so an already-seen image is presented without a
    /// read.
    private var detailPreviewImage: UIImage? {
        guard case .source(let source) = currentRecord.content else { return nil }
        return model.knowledgePreviews.image(for: source.preview?.hash)
    }
    private var observationPresentation: KnowledgeObservationPresentation? { KnowledgeObservationPresentation(record: currentRecord) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                if let observation = observationPresentation {
                    KnowledgeObservationStatement(presentation: observation)
                        .textSelection(.enabled)
                    observationEvidence(observation)
                } else if case .source(let source) = currentRecord.content {
                    sourceDetailHeader(source)
                    sourceSummary(source)
                    sourceDetails(source)
                } else {
                    TronSettingsGroup("Record", accent: .tronKnowledge) {
                        VStack(alignment: .leading, spacing: TronSpacing.md) {
                            Text(currentRecord.title)
                                .font(TronTypography.largeTitle)
                                .foregroundStyle(Color.tronTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Label("\(currentRecord.kind.label) · \(currentRecord.scope.label)", systemImage: currentRecord.kind.icon)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronKnowledge)
                            Text(currentRecord.summary)
                                .font(TronTypography.body)
                                .foregroundStyle(Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                    }
                    recordMetadata
                    noteMetadata
                    evidence
                }
                if let reflectedHandoff {
                    TronSettingsGroup("Generated reflected handoff", accent: .tronKnowledge) {
                        VStack(alignment: .leading, spacing: TronSpacing.md) {
                            Text(reflectedHandoff.summary)
                                .font(TronTypography.body)
                                .foregroundStyle(Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Start editable session from handoff") { onOpenDraft(reflectedHandoff) }
                                .buttonStyle(TronActionButtonStyle(accent: .tronKnowledge))
                        }
                        .padding(14)
                    }
                }
                if case .note(let note) = currentRecord.content, editing {
                    TronSettingsGroup("Edit note", accent: .tronKnowledge) {
                        VStack(alignment: .leading, spacing: TronSpacing.md) {
                            TextEditor(text: $noteBody)
                                .frame(minHeight: 180)
                                .tronTextEditor()
                            Button("Save note") { saveNote(note) }
                                .buttonStyle(TronActionButtonStyle(role: .primary, accent: .tronKnowledge))
                                .disabled(mutationInFlight)
                        }
                        .padding(14)
                    }
                }
                if let message {
                    Text(message)
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, TronSpacing.xlarge)
            .padding(.vertical, TronSpacing.large)
        }
        .tronScrollEdgeChrome()
        .task(id: "detail-preview-\(origin.profileID ?? "none"):\(origin.lifecycleGeneration ?? 0):\(origin.connectionID ?? 0):\(currentRecord.id):\(currentRecord.revisionId):\(currentRecord.content.sourcePreviewHash ?? "none")") {
            guard case .source(let source) = currentRecord.content, let preview = source.preview,
                  model.knowledgePresentationIdentity == origin, activity.allowsPresentationPublication else { return }
            _ = await model.knowledgePreviews.load(KnowledgePreviewRequest(recordID: currentRecord.id, revisionID: currentRecord.revisionId, reference: preview),
                                                   includeArchived: source.admission?.status == .archived)
        }
        .tronNavigationTitle(observationPresentation == nil ? "Entry Detail" : "Observation", accent: .tronKnowledge)
        .toolbar {
            if observationPresentation != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { technicalDetailsSheet = true } label: {
                        Image(systemName: "info.circle").foregroundStyle(Color.tronKnowledge)
                    }
                    .accessibilityLabel("Technical details")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Start editable session", systemImage: "plus.bubble") { onOpenDraft(currentRecord) }
                    if currentRecord.kind == .note {
                        Button(editing ? "Cancel editing" : "Edit note", systemImage: "pencil") {
                            editing.toggle()
                            if editing, case .note(let note) = currentRecord.content { noteBody = note.body ?? "" }
                        }
                    }
                    if currentRecord.kind == .source { Button("Assess with current interests", systemImage: "sparkles") { triage() } }
                    if let observation = observationPresentation {
                        Button("Reflect bounded handoff", systemImage: "sparkles") { reflect(observation.observation) }
                            .disabled(mutationInFlight)
                    }
                    Button("Correct record", systemImage: "arrow.triangle.2.circlepath") { correctionSheet = true }
                    Button("Exclude from Knowledge", systemImage: "eye.slash") { exclude() }
                    Button("Forget permanently", systemImage: "trash", role: .destructive) { forgetConfirmation = true }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Color.tronKnowledge) }
                .accessibilityLabel("Knowledge record actions")
            }
        }
        .foregroundStyle(Color.tronTextPrimary)
        .tronSettingsLayout()
        .task(id: "citations-\(currentRecord.id):\(currentRecord.revisionId)") { await loadCitationTitles() }
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .confirmationDialog("Forget this record?", isPresented: $forgetConfirmation) {
            Button("Forget", role: .destructive) { forget() }
        }
        .tronManagedSheet(isPresented: $technicalDetailsSheet, identity: "knowledge.technical.\(currentRecord.id)") {
            if let observation = observationPresentation {
                KnowledgeObservationTechnicalDetailsSheet(presentation: observation)
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { externalPageURL != nil }, set: { if !$0 { externalPageURL = nil } }), identity: "knowledge.external.\(currentRecord.id)") {
            if let externalPageURL {
                TronSafariView(url: externalPageURL)
                    .ignoresSafeArea(.container, edges: .all)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
        }
        .tronManagedSheet(isPresented: $correctionSheet, identity: "knowledge.correction.\(currentRecord.id)") {
            KnowledgeCorrectionView(record: currentRecord, origin: origin) { updated in
                // A managed child temporarily owns presentation publication while
                // its covered detail keeps data ownership. Identity, rather than
                // the parent's publication flag, admits this legitimate callback.
                guard model.knowledgePresentationIdentity == origin else { return }
                currentRecord = updated
                await onChanged()
                correctionSheet = false
            }
        }
        .navigationDestination(item: Binding(get: { linkedReader.record }, set: { _ in linkedReader.clear() })) { linked in
            KnowledgeDetailView(record: linked, origin: origin, onChanged: onChanged,
                                onOpenDraft: onOpenDraft, onOpenSession: onOpenSession, navigationAncestors: navigationAncestors)
        }
        .onDisappear { linkedReader.suspend() }
    }
    @ViewBuilder private var recordMetadata: some View {
        TronSettingsGroup("Metadata", accent: .tronKnowledge) {
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                Text("Revision: \(currentRecord.revisionId)")
                    .font(TronTypography.secondaryCodeDescription)
                    .foregroundStyle(Color.tronKnowledgeText)
                    .textSelection(.enabled)
                if let temporal = currentRecord.temporal {
                    Text([temporal.eventAt.map { "event \($0)" }, temporal.validFrom.map { "valid from \($0)" }, temporal.validTo.map { "valid to \($0)" }, temporal.reviewDue.map { "review \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .textSelection(.enabled)
                }
                if case .source(let source) = currentRecord.content {
                    Text("Capture: \(source.captureDisposition.rawValue)")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                    if source.captureDisposition != .complete {
                        Label("Evidence is \(source.captureDisposition.rawValue); generated text is not proof.", systemImage: "exclamationmark.triangle")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronAmber)
                    }
                }
                if case .note(let note) = currentRecord.content, let fields = note.fields {
                    Text("Structured qualifications")
                        .font(TronTypography.sheetSectionHeader)
                        .foregroundStyle(Color.tronKnowledge)
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: TronSpacing.xs) {
                            Text(field.field).font(TronTypography.bodySM.bold()).foregroundStyle(Color.tronTextPrimary)
                            Text("Value: \(jsonText(field.value))").font(TronTypography.body).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled)
                            if let subject = field.subject { Text("Subject: \(subject)").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary) }
                            Text("\(field.certainty.rawValue)\(field.validFrom.map { " · from \($0)" } ?? "")\(field.validTo.map { " · to \($0)" } ?? "")")
                                .font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                            citationLinks(field.evidence)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
    @ViewBuilder private func sourceDetailHeader(_ source: KnowledgeSourceContent) -> some View {
        KnowledgeEntryHeader(
            title: source.title,
            linkLabel: KnowledgeSourcePresentationPolicy.domain(source.uri),
            linkURL: KnowledgeSourcePresentationPolicy.originalURL(source),
            preview: detailPreviewImage,
            thumbnailLetters: KnowledgeSourcePresentationPolicy.thumbnailLetters(source),
            onOpenLink: { externalPageURL = $0 }
        )
    }

    @ViewBuilder private func sourceSummary(_ source: KnowledgeSourceContent) -> some View {
        TronSettingsGroup("Summary", accent: .tronKnowledge) {
            if let summary = KnowledgeSourcePresentationPolicy.summary(source) {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    Text(summary)
                        .font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let tags = source.summary?.tags, !tags.isEmpty { KnowledgeSummaryTags(tags: tags) }
                    if source.summary?.coverage == "sampled" {
                        Label("Based on the beginning of the saved text", systemImage: "text.magnifyingglass")
                            .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                    }
                }
                .padding(TronSettingsLayoutPolicy.rowHorizontalPadding)
            } else if source.text == nil {
                TronSettingsRow(icon: "text.badge.xmark", title: "No summary available", subtitle: "This entry has no saved readable text to summarize.", accent: .tronKnowledge)
            } else {
                Button { summarizeSource() } label: {
                    TronSettingsRow(
                        icon: "sparkles",
                        title: source.summary == nil ? "Generate AI summary" : "Regenerate AI summary",
                        subtitle: source.summary == nil ? "Summarizes the saved text with your Knowledge model; charges may apply." : "The saved text changed since the last summary.",
                        accent: .tronKnowledge
                    ) {
                        if mutationInFlight { TronPulseLoadingIndicator(accent: .tronKnowledge, size: 14) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(mutationInFlight || !admitsOrigin)
            }
        }
    }

    @ViewBuilder private func sourceDetails(_ source: KnowledgeSourceContent) -> some View {
        TronSettingsGroup("Details", accent: .tronKnowledge, surfaceStyle: .uncontained) {
            TronMetadataTable(accent: .tronKnowledge, rows: sourceMetadataRows(source), valueStyle: .preview)
        }
        if let notes = source.annotations, !notes.isEmpty {
            TronSettingsGroup("Saved notes", accent: .tronKnowledge) {
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    ForEach(Array(notes.prefix(20).enumerated()), id: \.offset) { _, note in
                        Text(note.text).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TronSettingsLayoutPolicy.rowHorizontalPadding)
            }
        }
        let related = relatedRecordIDs
        if !related.isEmpty {
            TronSettingsGroup("Related entries", accent: .tronKnowledge) {
                VStack(spacing: 0) {
                    ForEach(Array(related.enumerated()), id: \.element) { index, id in
                        if index > 0 { TronSettingsDivider(accent: .tronKnowledge) }
                        Button { openLinkedRecord(id: id, revisionID: nil) } label: {
                            TronSettingsRow(icon: "doc.text", title: citationTitles[id] ?? citationTitles.first(where: { $0.key.hasPrefix("\(id)|") })?.value ?? "Related entry", accent: .tronKnowledge) {
                                Image(systemName: "chevron.right").font(TronTypography.caption).foregroundStyle(Color.tronKnowledge)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if let links = source.linkedUrls?.compactMap(KnowledgeSourcePresentationPolicy.safeURL), !links.isEmpty {
            TronSettingsGroup("Links in this entry", accent: .tronKnowledge) {
                VStack(spacing: 0) {
                    ForEach(Array(links.prefix(8).enumerated()), id: \.offset) { index, url in
                        if index > 0 { TronSettingsDivider(accent: .tronKnowledge) }
                        Button { externalPageURL = url } label: {
                            TronSettingsRow(icon: "link", title: url.host ?? url.absoluteString, subtitle: url.path.isEmpty || url.path == "/" ? nil : url.path, subtitleLineLimit: 1, accent: .tronKnowledge) {
                                Image(systemName: "arrow.up.right").font(TronTypography.caption).foregroundStyle(Color.tronKnowledge)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if source.captureDisposition != .complete, let reason = source.captureReason {
            TronSettingsGroup("Capture coverage", accent: .tronKnowledge) {
                Text(reason).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TronSettingsLayoutPolicy.rowHorizontalPadding)
            }
        }
        if let evidenceMessage { TronSettingsCaption(evidenceMessage) }
        if linkedReader.loading { TronLoadingState(label: "Opening related entry…", accent: .tronKnowledge) }
        if let linkedRecordError = linkedReader.error { Text(linkedRecordError).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronAmber) }
    }

    private func sourceMetadataRows(_ source: KnowledgeSourceContent) -> [TronMetadataTableRow] {
        var rows: [TronMetadataTableRow] = []
        func add(_ title: String, _ value: String) { rows.append(TronMetadataTableRow(id: title, title: title, value: value)) }
        add("Type", KnowledgeSourcePresentationPolicy.sourceType(source) ?? "Source")
        if let published = KnowledgeSourcePresentationPolicy.publishedAt(source) { add("Published", humanDate(published)) }
        if let saved = source.sourceSavedAt { add("Saved in \(source.identity?.provider.capitalized ?? "source")", humanDate(saved)) }
        add("Captured by Tron", humanDate(source.capturedAt))
        add("Capture", source.captureDisposition.rawValue.capitalized)
        if let classification = source.assessment?.classification { add("Intake classification", classification) }
        add("Saved by", source.identity?.provider.capitalized ?? source.origin?.capitalized ?? "Unknown")
        if let identity = source.identity { add("Origin ID", identity.itemId) }
        if let mediaType = source.mediaType { add("Media type", mediaType) }
        add("Revision", currentRecord.revisionId)
        return rows
    }

    /// Other entries this one cites or is related to, deduplicated and opened at
    /// their current revision.
    private var relatedRecordIDs: [String] {
        var seen = Set<String>(); var ids: [String] = []
        for id in currentRecord.relations.map(\.recordId) + currentRecord.provenance.evidence.compactMap(\.recordId) where id != currentRecord.id && seen.insert(id).inserted { ids.append(id) }
        return Array(ids.prefix(24))
    }

    private func humanDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return value }
        let output = DateFormatter(); output.dateStyle = .medium; output.timeStyle = .none; return output.string(from: date)
    }

    private var evidence: some View {
        TronSettingsGroup("Evidence", accent: .tronKnowledge) {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                citationLinks(currentRecord.provenance.evidence)
                if case .observation(let observation) = currentRecord.content {
                    ForEach(Array(observation.items.enumerated()), id: \.offset) { _, item in citationLinks(item.evidence ?? []) }
                }
                if case .note(let note) = currentRecord.content, let contrary = note.contraryEvidence {
                    Text("Contrary evidence").font(TronTypography.bodySM.bold()).foregroundStyle(Color.tronAmber)
                    citationLinks(contrary)
                }
                if let evidenceMessage { Text(evidenceMessage).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary) }
                if linkedReader.loading { TronLoadingState(label: "Opening linked evidence…", accent: .tronKnowledge) }
                if let linkedRecordError = linkedReader.error { Text(linkedRecordError).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronAmber) }
            }
            .padding(14)
        }
    }
    @ViewBuilder private func citationLinks(_ refs: [KnowledgeEvidenceRef]) -> some View {
        ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
            if let citation = ref.sessionEntry {
                Button("Open originating session · \(citation.entryId)") { openSessionEvidence(citation) }
                    .buttonStyle(TronRowButtonStyle(accent: .tronKnowledge))
            } else if let recordID = ref.recordId, recordID != currentRecord.id {
                let title = citationTitles["\(recordID)|\(ref.revisionId ?? "latest")"] ?? citationTitles[recordID] ?? ref.locator.flatMap { URL(string: $0)?.host } ?? "Related source"
                Button("Open \(title)") { openLinkedRecord(id: recordID, revisionID: ref.revisionId) }
                    .buttonStyle(TronRowButtonStyle(accent: .tronKnowledge))
            } else if let hash = ref.objectHash {
                Text("Retained object \(hash.prefix(12))…").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextSecondary).textSelection(.enabled)
            } else {
                Text("Evidence unavailable").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronAmber)
            }
        }
    }

    private func jsonText(_ value: JSONValue) -> String { switch value { case .string(let value): return value; case .number(let value): return String(value); case .bool(let value): return value ? "true" : "false"; case .null: return "null"; case .array(let values): return "[\(values.prefix(20).map(jsonText).joined(separator: ", "))]"; case .object(let values): return "{\(values.keys.sorted().prefix(20).compactMap { key in values[key].map { "\(key): \(jsonText($0))" } }.joined(separator: ", "))}" } }
    @ViewBuilder private var noteMetadata: some View {
        if case .note(let note) = currentRecord.content {
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                if let freshness = note.freshness { Text("Freshness: \(freshness.rawValue)").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary) }
                if let contrary = note.contraryEvidence, !contrary.isEmpty { Text("Contrary evidence retained: \(contrary.count)").font(TronTypography.caption).foregroundStyle(Color.tronAmber) }
            }
        }
    }
    private func observationEvidence(_ observation: KnowledgeObservationPresentation) -> some View {
        TronSettingsGroup("Evidence", accent: .tronKnowledge) {
            TronSettingsRow(icon: "bubble.left.and.bubble.right", title: originatingSessionTitle(observation.sessionID)) {
                Button {
                    guard admitsOrigin else { evidenceMessage = "Gateway changed; reopen this entry."; return }
                    onOpenSession(observation.sessionID, observation.entryID)
                } label: {
                    TronInlineActionLabel("Open session", accent: .tronKnowledge)
                }
                .buttonStyle(.plain)
            }
            if let evidenceMessage {
                TronSettingsCaption(evidenceMessage).padding(14)
            }
        }
    }
    private func originatingSessionTitle(_ sessionID: String) -> String {
        guard model.knowledgePresentationIdentity == origin else { return "Originating session" }
        // Session names are disposable catalog copy. Navigation still uses the
        // exact Gateway/session/entry citation even when the row is off-page.
        return model.sessions.first(where: { $0.id == sessionID })?.title ?? "Originating session"
    }
    /// One bounded rows request resolves every related-entry title this detail
    /// shows; a title is a convenience, so a failure leaves the fallback label.
    private func loadCitationTitles() async {
        let related = relatedRecordIDs.filter { id in
            citationTitles[id] == nil && !citationTitles.keys.contains { $0.hasPrefix("\(id)|") }
        }
        guard !related.isEmpty else { return }
        let requestedIdentity = origin
        do {
            let page = try await model.knowledge.sourceRows(ids: Array(related.prefix(KnowledgeChangeGating.maximumRecordIDs)), includeArchived: true, includePending: true)
            guard !Task.isCancelled, model.knowledgePresentationIdentity == requestedIdentity,
                  activity.allowsPresentationPublication else { return }
            for row in page.rows { citationTitles[row.id] = row.title.isEmpty ? "Related entry" : row.title }
        } catch {
            return
        }
    }

    private func openLinkedRecord(id: String, revisionID: String?) {
        guard admitsOrigin else { evidenceMessage = "Gateway changed; reopen this entry."; return }
        guard !navigationAncestors.contains(id) else { evidenceMessage = "This source is already open. Use Back to return to it."; return }
        guard navigationAncestors.count < 32 else { evidenceMessage = "Return to the library to open another source."; return }
        let requestIdentity = origin
        Task { @MainActor in
            await linkedReader.load(id: id, revisionID: revisionID,
                request: { id, revision in try await model.knowledge.read(id: id, revisionID: revision) },
                isCurrent: { model.knowledgePresentationIdentity == requestIdentity && activity.allowsPresentationPublication })
        }
    }
    private func openSessionEvidence(_ citation: KnowledgeSessionEntryCitation) {
        guard admitsOrigin else { evidenceMessage = "Gateway changed; reopen this entry."; return }
        onOpenSession(citation.sessionId, citation.entryId)
    }
    private func reflect(_ observation: KnowledgeObservationContent) {
        guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }
        guard !mutationInFlight else { return }
        mutationInFlight = true
        reflectionRequestGeneration &+= 1
        let requestGeneration = reflectionRequestGeneration
        let requestIdentity = origin
        Task { @MainActor in
            guard requestGeneration == reflectionRequestGeneration, model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let result = try await model.knowledge.reflect(sessionID: observation.range.sessionId, sourceRevisionIDs: [currentRecord.revisionId])
                guard requestGeneration == reflectionRequestGeneration, model.knowledgePresentationIdentity == requestIdentity,
                      activity.allowsPresentationPublication else { return }
                if case .note = result.record.content { reflectedHandoff = result.record; message = "Reflected handoff generated; verify it before acting." } else { message = "Reflected handoff updated." }
                mutationInFlight = false
            } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return }
            catch { guard requestGeneration == reflectionRequestGeneration, model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription }
        }
    }
    private func summarizeSource() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; let revision = currentRecord.revisionId; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; do { let result = try await model.knowledge.summarize(sourceID: currentRecord.id, expectedRevision: revision); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; currentRecord = result.record; mutationInFlight = false; message = "AI summary generated from the saved evidence."; await onChanged() } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
    private func triage() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { let result = try await model.knowledge.triage(sourceID: currentRecord.id, expectedRevision: currentRecord.revisionId); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; currentRecord = result.source; mutationInFlight = false; message = "Assessment updated (\(result.assessment.freshness.rawValue))." } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
    private func saveNote(_ note: KnowledgeNoteContent) { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { let result = try await model.knowledge.updateNote(id: currentRecord.id, expectedRevision: currentRecord.revisionId, record: KnowledgeRecordDraft(id: currentRecord.id, createdAt: currentRecord.createdAt, updatedAt: nil, kind: .note, scope: currentRecord.scope, provenance: currentRecord.provenance, temporal: currentRecord.temporal, relations: currentRecord.relations, content: .note(KnowledgeNoteContent(title: note.title, body: noteBody, fields: note.fields, role: note.role, confirmed: note.confirmed, contraryEvidence: note.contraryEvidence, freshness: note.freshness, privacyScope: note.privacyScope, usageConstraint: note.usageConstraint))), confirmedByUser: note.confirmed); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; currentRecord = result.record; mutationInFlight = false; message = "Saved"; await onChanged() } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
    private func exclude() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { _ = try await model.knowledge.setExclusion(recordID: currentRecord.id, expectedRevision: currentRecord.revisionId, excluded: true); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; dismiss() } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
    private func forget() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { _ = try await model.knowledge.forget(id: currentRecord.id, expectedRevision: currentRecord.revisionId, reason: "Forgotten from iOS"); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; dismiss() } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
}

/// Grounded tags generated together with a content summary.
private struct KnowledgeSummaryTags: View {
    let tags: [KnowledgeSourceSummaryTag]

    var body: some View {
        ToolChipFlowLayout(spacing: TronSpacing.sm) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                Label(tag.label, systemImage: tag.kind == "semantic" ? "sparkle" : "number")
                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronKnowledgeText)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.tronKnowledge.opacity(0.12), in: Capsule())
            }
        }
    }
}

struct KnowledgeConfigurationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var config: KnowledgeConfig?
    @State private var chosenModel: ModelRef?
    @State private var interestsText = ""
    @State private var saving = false
    @State private var error: String?
    @State private var identity: KnowledgePresentationIdentity?
    private var supportsGlobalObservation: Bool { model.gatewayInfo?.capabilities.contains(KnowledgeRPCClient.globalObservationCapability) == true }

    var body: some View {
        KnowledgeFormSheet(title: "Observation", isWorking: saving, actionDisabled: config == nil, onAction: save) {
            if config == nil && error == nil { TronLoadingState(label: "Loading configuration…") }
            TronSettingsGroup("Observer", accent: .tronKnowledge) {
                TronSelectionSheetRow(icon: "cpu", title: "Model", value: chosenModel?.id ?? "Choose", accent: .tronKnowledge) {
                    ModelPicker(selection: $chosenModel, models: model.providerCatalog(for: .global)?.models.filter(\.available) ?? [])
                        .tronNavigationTitle("Observation model", accent: .tronKnowledge)
                        .presentationDetents([.large])
                }
            }
            .disabled(config == nil)
            .tronSettingsCaption("The model is used for future eligible turns; earlier turns are not backfilled.")
            TronSettingsGroup("Observation", accent: .tronKnowledge) {
                TronToggleRow(icon: "globe", title: "Observe all Tron sessions",
                              detail: "When enabled, save future observations from every Tron conversation. Excluded conversations and projects stay excluded.", accent: .tronKnowledge,
                              isOn: Binding(get: { config?.observation.enabled ?? false }, set: { config?.observation.enabled = $0 }))
                    .disabled(config == nil || (!supportsGlobalObservation && config?.observation.enabled != true))
            }
            .tronSettingsCaption("This covers Tron conversations only, not other apps, files, or delegated-agent transcripts.")
            if !supportsGlobalObservation {
                TronSettingsNotice(message: "Update this Gateway to enable all-session observation.", accent: .tronAmber)
            }
            TronSettingsGroup("Current interests", accent: .tronKnowledge, surfaceStyle: .uncontained) {
                TextEditor(text: $interestsText).frame(minHeight: 120).tronTextEditor()
                    .accessibilityLabel("Current interests")
            }
            .tronSettingsCaption("One interest per line, up to 50. Interests guide source triage and do not enable observation.")
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
        .task { await load() }
    }

    private func load() async {
        let requestIdentity = model.knowledgePresentationIdentity
        do {
            let loaded = try await model.knowledge.status()
            guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity, requestIdentity.profileID != nil else { return }
            identity = requestIdentity
            config = loaded.config
            interestsText = loaded.config.currentInterests.joined(separator: "\n")
            if let value = loaded.config.observation.model {
                let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 { chosenModel = ModelRef(provider: parts[0], id: parts[1]) }
            }
        } catch {
            guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard !saving, var config else { return }
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { error = "Gateway changed; reopen configuration."; return }
        if let chosenModel { config.observation.model = chosenModel.contextWindowKey }
        if config.observation.enabled && !KnowledgeObservationConfigurationPolicy.admitsEnable(hasModel: config.observation.model != nil, supportsGlobalObservation: supportsGlobalObservation) {
            error = config.observation.model == nil ? "Choose a model before enabling observation." : "Update this Gateway before enabling all-session observation."
            return
        }
        saving = true
        config = KnowledgeObservationConfigurationPolicy.applyingGlobalGrant(config, enabled: config.observation.enabled)
        config.currentInterests = interestsText.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(50).map { String($0.prefix(500)) }
        Task { @MainActor in
            guard model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                _ = try await model.knowledge.configure(config, capabilities: model.gatewayInfo?.capabilities ?? [])
                guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
                saving = false; dismiss()
            } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { saving = false } }
            catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; saving = false; self.error = error.localizedDescription }
        }
    }
}

private struct KnowledgeCorrectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    let record: KnowledgeRecord
    let origin: KnowledgePresentationIdentity
    let onComplete: (KnowledgeRecord) async -> Void
    @State private var text: String
    @State private var saving = false
    @State private var error: String?

    init(record: KnowledgeRecord, origin: KnowledgePresentationIdentity, onComplete: @escaping (KnowledgeRecord) async -> Void) {
        self.record = record; self.origin = origin; self.onComplete = onComplete
        _text = State(initialValue: record.summary)
    }
    var body: some View {
        KnowledgeFormSheet(title: "Correct Knowledge", isWorking: saving,
                           actionDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onAction: save) {
            TronSettingsGroup("Correction", accent: .tronKnowledge, surfaceStyle: .uncontained) {
                TextEditor(text: $text).frame(minHeight: 180).tronTextEditor().accessibilityLabel("Correction")
            }
            .tronSettingsCaption("This creates a new immutable revision and preserves the original as corrected evidence.")
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
    }
    private func save() {
        guard !saving else { return }
        guard model.knowledgePresentationIdentity == origin, activity.allowsPresentationPublication else { error = "Gateway changed; reopen this entry."; return }
        saving = true
        let replacement = KnowledgeRecordDraft(id: record.id, createdAt: record.createdAt, updatedAt: nil, kind: record.kind, scope: record.scope, provenance: KnowledgeCorrectionPolicy.provenance(for: record), temporal: record.temporal, relations: record.relations, content: KnowledgeCorrectionPolicy.content(for: record, replacementText: text))
        let relation = KnowledgeRelation(type: .corrects, recordId: record.id, revisionId: record.revisionId, field: nil)
        Task { @MainActor in
            guard model.knowledgePresentationIdentity == origin else { return }
            do { let result = try await model.knowledge.correct(id: record.id, expectedRevision: record.revisionId, replacement: replacement, relation: relation, confirmedByUser: true); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == origin else { return }; saving = false; await onComplete(result.record) }
            catch is CancellationError { if model.knowledgePresentationIdentity == origin { saving = false }; return }
            catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == origin else { return }; saving = false; self.error = error.localizedDescription }
        }
    }
}

private struct KnowledgeCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    let onComplete: () async -> Void
    @State private var title = ""
    @State private var uri = ""
    @State private var scope: KnowledgeScope = .research
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        KnowledgeFormSheet(title: "Capture URL", actionTitle: "Capture", isWorking: saving, actionDisabled: !valid, onAction: capture) {
            TronSettingsGroup("Source", accent: .tronKnowledge) {
                TronTextSettingRow(icon: "textformat", title: "Title", value: $title)
                TronSettingsDivider(accent: .tronKnowledge)
                TronTextSettingRow(icon: "link", title: "URL", value: $uri, keyboard: .URL)
                TronSettingsDivider(accent: .tronKnowledge)
                TronSelectionRow(icon: "folder", title: "Scope", value: scope.label) {
                    ForEach(KnowledgeScope.allCases, id: \.self) { value in Button(value.label) { scope = value } }
                }
            }
            .tronSettingsCaption("The Gateway performs bounded safe fetching and records capture quality.")
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
    }
    private var valid: Bool { guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased()), url.user == nil, url.password == nil else { return false }; return true }
    private func capture() { guard valid else { error = "Use an http(s) URL without credentials."; return }; guard !saving else { return }; saving = true; let identity = model.knowledgePresentationIdentity; let sourceURL = uri; let sourceTitle = title
        Task { @MainActor in guard model.knowledgePresentationIdentity == identity else { return }; do { _ = try await model.knowledge.captureURL(url: sourceURL, title: sourceTitle, scope: scope); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; saving = false; await onComplete(); dismiss() } catch is CancellationError { if model.knowledgePresentationIdentity == identity { saving = false }; return } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; saving = false; self.error = error.localizedDescription } }
    }
}

private struct KnowledgeNoteCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    let onComplete: () async -> Void
    @State private var title = ""
    @State private var noteText = ""
    @State private var scope: KnowledgeScope = .personal
    @State private var role: KnowledgeNoteRole = .fact
    @State private var confirmed = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        KnowledgeFormSheet(title: "New note", isWorking: saving,
                           actionDisabled: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onAction: save) {
            TronSettingsGroup("Note", accent: .tronKnowledge) {
                TronTextSettingRow(icon: "textformat", title: "Title", value: $title)
                TronSettingsDivider(accent: .tronKnowledge)
                TronSelectionRow(icon: "tag", title: "Role", value: role.rawValue.capitalized) {
                    ForEach(KnowledgeNoteRole.allCases, id: \.self) { value in Button(value.rawValue.capitalized) { role = value } }
                }
                TronSettingsDivider(accent: .tronKnowledge)
                TronSelectionRow(icon: "folder", title: "Scope", value: scope.label) {
                    ForEach(KnowledgeScope.allCases, id: \.self) { value in Button(value.label) { scope = value } }
                }
                TronSettingsDivider(accent: .tronKnowledge)
                TronToggleRow(icon: "checkmark.seal", title: "Confirmed by me", isOn: $confirmed)
            }
            TronSettingsGroup("Content", accent: .tronKnowledge, surfaceStyle: .uncontained) {
                TextEditor(text: $noteText).frame(minHeight: 180).tronTextEditor().accessibilityLabel("Note content")
            }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
    }
    private func save() {
        guard !saving else { return }
        saving = true
        let identity = model.knowledgePresentationIdentity; let record = KnowledgeRecordDraft(id: nil, createdAt: nil, updatedAt: nil, kind: .note, scope: scope, provenance: KnowledgeProvenance(actor: .user, source: "ios-note", sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [], content: .note(KnowledgeNoteContent(title: title, body: noteText.isEmpty ? nil : noteText, fields: nil, role: role, confirmed: confirmed, contraryEvidence: nil, freshness: .current, privacyScope: "private", usageConstraint: nil)))
        Task { @MainActor in guard model.knowledgePresentationIdentity == identity else { return }; do { _ = try await model.knowledge.createNote(record, confirmedByUser: confirmed); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; await onComplete(); dismiss() } catch is CancellationError { saving = false; return } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; saving = false; self.error = error.localizedDescription } }
    }
}
