import SwiftUI
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
    static func admits(cursor: String?, search: String, loadingMore: Bool) -> Bool {
        cursor != nil && !loadingMore && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

/// Dashboard rhythm. Catalogue rows pack closer than the section rhythm so a
/// long retained list stays scannable; section boundaries add their own inset.
enum KnowledgeDashboardLayout {
    static let recordSpacing: CGFloat = 8
}

enum KnowledgeImportPresentationPolicy {
    static func corpusProgress(planned: Int, selected: Int, offset: Int) -> String {
        "\(min(max(0, planned), max(0, offset) + max(0, selected))) of \(max(0, planned))"
    }

    static func completionMessage(plan: KnowledgeImportPlan, result: KnowledgeImportResult, offset: Int) -> String {
        let processed = result.imported + result.resumed + result.skipped
        let expected = max(plan.planned, plan.selected)
        guard result.failed == 0, processed == result.selected else {
            return "Import incomplete (\(processed) of \(result.selected) admitted; \(result.failed) failed); retry this operation to continue."
        }
        if result.completed && result.progress.remaining == 0 { return "Import complete (\(result.imported) imported)." }
        return "Batch complete (\(result.progress.completed) of \(expected)); continuing with \(result.progress.remaining) remaining."
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
    @State private var records: [KnowledgeRecord] = []
    @State private var area: KnowledgeDashboardArea = .chronicle
    @State private var librarySelection: KnowledgeDashboardSection = .sources
    @State private var sourceVisibility: KnowledgeSourceVisibility = .saved
    @State private var chronicleScope: KnowledgeScope?
    @State private var libraryScope: KnowledgeScope?
    @State private var selected: KnowledgeRecord?
    @State private var selectedIdentity: KnowledgePresentationIdentity?
    @State private var pendingDetailAction: DetailAction?
    private enum DetailAction { case draft(KnowledgeRecord), session(String, String) }
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var nextCursor: String?
    @State private var loadingMore = false
    @State private var status: KnowledgeStatus?
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
        KnowledgeCatalogRequestKey(section: section, kind: requestKind, scope: scope, search: search, sourceVisibility: activeSourceVisibility)
    }

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
        .tronManagedSheet(item: $selected, identity: { "knowledge.detail.\($0.id)" }, onDismiss: finishDetailDismissal) { record in
            KnowledgeDetailSheet(record: record, origin: selectedIdentity ?? model.knowledgePresentationIdentity,
                                 onChanged: reload,
                                 onOpenDraft: { stageDetailAction(.draft($0)) },
                                 onOpenSession: { stageDetailAction(.session($0, $1)) })
                .environment(model)
        }
        .onChange(of: area) { _, _ in invalidateCatalogueRequests(clearRecords: true) }
        .onChange(of: librarySelection) { _, _ in invalidateCatalogueRequests(clearRecords: true) }
        .onChange(of: sourceVisibility) { _, _ in invalidateCatalogueRequests(clearRecords: true) }
        .onChange(of: chronicleScope) { _, _ in invalidateCatalogueRequests(clearRecords: true) }
        .onChange(of: libraryScope) { _, _ in invalidateCatalogueRequests(clearRecords: true) }
        .onChange(of: search) { _, _ in invalidateCatalogueRequests(clearRecords: true) }
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in
            // Retire both the visible page and any manually spawned page task;
            // the next task must carry the new Gateway identity from its start.
            loadGeneration += 1
            loadingMore = false
            coverageStore.reset()
            coverageSheet = false
            records.removeAll(); selected = nil; selectedIdentity = nil; pendingDetailAction = nil
            nextCursor = nil; status = nil; error = nil
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
        .task(id: "\(section.rawValue)/\(activeSourceVisibility.rawValue)/\(scope?.rawValue ?? "all")/\(search)/\(activity.allowsPresentationPublication)/\(model.knowledgePresentationIdentity.profileID ?? "none")/\(model.knowledgePresentationIdentity.lifecycleGeneration ?? -1)/\(model.knowledgePresentationIdentity.connectionID ?? -1)/\(model.knowledgeInvalidationRevision)") {
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
        .onDisappear { coverageStore.suspend() }
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
        search = ""
        showingSearch = false
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
        if loading && records.isEmpty {
            TronLoadingState(label: "Loading Knowledge…", accent: .tronKnowledge)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
        } else if records.isEmpty, let error {
            TronPlaceholderState(title: "Knowledge unavailable", detail: error,
                                 icon: "externaldrive.badge.xmark", accent: .tronKnowledge,
                                 actionTitle: "Retry", action: { Task { await reload() } })
                .frame(minHeight: minimumHeight)
        } else if records.isEmpty {
            let filtered = scope != nil || !search.isEmpty || section != .chronicle || sourceVisibility != .saved
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                TronPlaceholderState(title: filtered ? "No matching Knowledge" : "No Knowledge yet",
                                     detail: filtered ? "Adjust your search or filters to see more records." : "Observations, links, and notes retained by this Gateway will appear here.",
                                     icon: filtered ? "line.3.horizontal.decrease.circle" : "book.closed", accent: .tronKnowledge)
                    .frame(minHeight: minimumHeight)
                if KnowledgeCatalogPagePolicy.offersContinuation(nextCursor: nextCursor, loadingMore: loadingMore) {
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
            let previewIdentity = model.knowledgePresentationIdentity
            ForEach(records) { record in
                Button {
                    selected = record
                    selectedIdentity = previewIdentity
                } label: { KnowledgeRecordRow(record: record, previewLoader: { reference, record in
                        await readPreview(reference, record: record, identity: previewIdentity)
                    }, presentationIdentity: previewIdentity) }
                    .buttonStyle(.plain)
            }
            if KnowledgeCatalogPagePolicy.offersContinuation(nextCursor: nextCursor, loadingMore: loadingMore) {
                loadMoreButton
            }
        }
    }

    @MainActor private func readPreview(_ reference: KnowledgeObjectRef, record: KnowledgeRecord, identity: KnowledgePresentationIdentity) async -> KnowledgeObjectRead? {
        guard model.knowledgePresentationIdentity == identity, activity.allowsPresentationPublication else { return nil }
        let response = try? await model.knowledge.readObject(reference, recordID: record.id, revisionID: record.revisionId)
        guard !Task.isCancelled, model.knowledgePresentationIdentity == identity, activity.allowsPresentationPublication else { return nil }
        return response
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

    private func invalidateCatalogueRequests(clearRecords: Bool = false) {
        loadGeneration &+= 1
        loadingMore = false
        nextCursor = nil
        if clearRecords {
            records.removeAll()
            status = nil
            error = nil
        }
    }

    private func reload() async {
        loadGeneration += 1; let generation = loadGeneration; let identity = model.knowledgePresentationIdentity
        let requestedSection = section
        let requestedKind = requestKind
        let requestedScope = scope
        let requestedSearch = search
        let requestedVisibility = activeSourceVisibility
        let requestedKey = KnowledgeCatalogRequestKey(section: requestedSection, kind: requestedKind, scope: requestedScope, search: requestedSearch, sourceVisibility: requestedVisibility)
        guard activity.allowsPresentationPublication, identity.profileID != nil, identity.lifecycleGeneration != nil else { return }
        loading = true; error = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            async let loadedStatus = model.knowledge.status()
            var response: KnowledgeListResponse
            if requestedSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                response = try await model.knowledge.list(kind: requestedKind, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), limit: 50)
            } else {
                let found = try await model.knowledge.search(query: requestedSearch, kind: requestedKind, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), limit: 50)
                response = KnowledgeListResponse(records: found.hits.map { $0.record }, nextCursor: nil, stateRevision: found.stateRevision)
            }
            response = KnowledgeListResponse(records: KnowledgeCatalogPagePolicy.visibleRecords(response.records, in: requestedSection, sourceVisibility: requestedVisibility), nextCursor: response.nextCursor, stateRevision: response.stateRevision)
            let currentStatus = try await loadedStatus
            guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                  activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            records = response.records; nextCursor = response.nextCursor; status = currentStatus
            guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                  activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
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
    private func loadMore() {
        guard KnowledgeCatalogPaginationPolicy.admits(cursor: nextCursor, search: search, loadingMore: loadingMore), let cursor = nextCursor else { return }
        loadingMore = true
        let generation = loadGeneration
        let query = search
        let requestedKind = requestKind
        let requestedScope = scope
        let requestedSection = section
        let requestedVisibility = activeSourceVisibility
        let requestedKey = KnowledgeCatalogRequestKey(section: requestedSection, kind: requestedKind ?? requestedSection.kind, scope: requestedScope, search: query, sourceVisibility: requestedVisibility)
        let identity = model.knowledgePresentationIdentity
        Task { @MainActor in
            defer { if generation == loadGeneration { loadingMore = false } }
            guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                  activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            do {
                let page = try await model.knowledge.list(kind: requestedKind ?? requestedSection.kind, scope: requestedScope, includeArchived: KnowledgeCatalogRequestPolicy.includesArchived(section: requestedSection, visibility: requestedVisibility), includePending: KnowledgeCatalogRequestPolicy.includesPending(section: requestedSection, visibility: requestedVisibility), sourceAdmission: KnowledgeCatalogRequestPolicy.sourceAdmission(section: requestedSection, visibility: requestedVisibility), cursor: cursor, limit: 50)
                let visiblePage = KnowledgeListResponse(records: KnowledgeCatalogPagePolicy.visibleRecords(page.records, in: requestedSection, sourceVisibility: requestedVisibility), nextCursor: page.nextCursor, stateRevision: page.stateRevision)
                guard generation == loadGeneration, KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                      activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity,
                      visiblePage.nextCursor != cursor else { return }
                // A Gateway page may contain only another visibility class (or
                // records already admitted by a retried page). Advance the
                // canonical cursor even when this projection adds no rows;
                // rejecting that page made Archived appear empty with an inert
                // continuation button.
                let newRecords = visiblePage.records.filter { candidate in !records.contains(candidate) }
                records.append(contentsOf: newRecords); nextCursor = visiblePage.nextCursor
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == loadGeneration,
                      KnowledgeCatalogRequestFence.accepts(requestedKey, current: requestKey()),
                      activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == identity else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func stageDetailAction(_ action: DetailAction) {
        guard model.knowledgePresentationIdentity == selectedIdentity, pendingDetailAction == nil else { return }
        // The existing session/new-session owner must not present through an
        // observation sheet that is still dismissing.
        pendingDetailAction = action
        selected = nil
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
struct KnowledgeRecordRow: View {
    typealias PreviewLoader = @Sendable (KnowledgeObjectRef, KnowledgeRecord) async -> KnowledgeObjectRead?
    let record: KnowledgeRecord
    let previewLoader: PreviewLoader?
    let presentationIdentity: KnowledgePresentationIdentity?

    init(record: KnowledgeRecord, previewLoader: PreviewLoader? = nil, presentationIdentity: KnowledgePresentationIdentity? = nil) {
        self.record = record; self.previewLoader = previewLoader; self.presentationIdentity = presentationIdentity
    }

    var body: some View {
        Group {
            if let observation = KnowledgeObservationPresentation(record: record) {
                KnowledgeObservationStatement(presentation: observation, preview: true)
                    .accessibilityElement(children: .combine)
            } else if case .source(let source) = record.content {
                KnowledgeSourceRow(record: record, source: source, previewLoader: previewLoader, presentationIdentity: presentationIdentity)
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

enum KnowledgePreviewDecoder {
    nonisolated static func downsample(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

struct KnowledgeSourceThumbnail: View {
    let source: KnowledgeSourceContent
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color.tronKnowledge.opacity(0.16))
            Text(KnowledgeSourcePresentationPolicy.thumbnailLetters(source))
                .font(TronTypography.sans(size: size * 0.25, weight: .bold))
                .foregroundStyle(Color.tronKnowledge)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Preview for \(source.title)")
    }
}

struct KnowledgeSourceRow: View {
    let record: KnowledgeRecord
    let source: KnowledgeSourceContent
    let previewLoader: KnowledgeRecordRow.PreviewLoader?
    let presentationIdentity: KnowledgePresentationIdentity?
    @State private var previewImage: UIImage?
    @State private var previewTicket = UUID()

    var body: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Preview for \(source.title)")
            } else {
                KnowledgeSourceThumbnail(source: source, size: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text(source.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(2)
                if let summary = KnowledgeSourcePresentationPolicy.summary(source) {
                    Text(summary)
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: TronSpacing.xs) {
                    if let domain = KnowledgeSourcePresentationPolicy.domain(source.uri) { Text(domain) }
                    if let type = KnowledgeSourcePresentationPolicy.sourceType(source) { Text("· \(type)") }
                }
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronKnowledgeText)
                .lineLimit(1)
            }
            .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens source details")
        .task(id: "\(presentationIdentity?.profileID ?? "none"):\(presentationIdentity?.lifecycleGeneration ?? 0):\(presentationIdentity?.connectionID ?? 0):\(record.id):\(record.revisionId):\(source.preview?.hash ?? "none")") {
            previewImage = nil
            previewTicket = UUID()
            let ticket = previewTicket
            guard let reference = source.preview, let previewLoader else { return }
            guard let response = await previewLoader(reference, record), !Task.isCancelled, ticket == previewTicket,
                  response.offset == 0, response.nextOffset == nil,
                  let data = Data(base64Encoded: response.base64), data.count == response.bytes,
                  response.totalBytes == response.bytes, data.count <= 512_000,
                  let image = await KnowledgePreviewDecoder.downsample(data), !Task.isCancelled, ticket == previewTicket else { return }
            previewImage = image
        }
    }
}

struct KnowledgeSavedTextReader: View {
    let text: String?
    let reference: KnowledgeObjectRef?
    let recordID: String
    let revisionID: String
    let label: String
    @Bindable var readers: KnowledgeObjectReaderStore
    var loadNext: ((KnowledgeObjectRef, Int) -> Void)? = nil
    @State private var page = 0
    private let pageSize = 12_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                Text(label.capitalized)
                    .font(TronTypography.largeTitle)
                    .foregroundStyle(Color.tronKnowledge)
                if let text, !text.isEmpty {
                    pagedText(KnowledgeSourcePresentationPolicy.decodeSavedTextEntities(text))
                } else if let reference { let state = state(for: reference)
                    if state.loading && state.bytes.isEmpty { TronLoadingState(label: "Loading saved text…", accent: .tronKnowledge) }
                    else if let error = state.error, state.bytes.isEmpty { Text(error).font(TronTypography.body).foregroundStyle(Color.tronAmber) }
                    else if state.bytes.isEmpty { Text("No readable text is available for this source.").font(TronTypography.body).foregroundStyle(Color.tronTextSecondary) }
                    else {
                        let full = KnowledgeObjectPresentationPolicy.renderedText(state.bytes, mediaType: reference.mediaType, label: label)
                        // Raw evidence stays verbatim; only the readable-text presentation decodes entities.
                        pagedText(full)
                        if let error = state.error { Text(error).foregroundStyle(Color.tronAmber) }
                        if let next = state.nextOffset, let loadNext {
                            TronPaginationButton(label: "Load more of this file", loadingLabel: "Loading…", icon: "arrow.down", isLoading: state.loading, accent: .tronKnowledge) { loadNext(reference, next) }
                        }
                        Text("\(state.bytes.count) of \(state.totalBytes ?? reference.bytes) bytes loaded")
                            .font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                    }
                } else {
                    Text("Saved text is unavailable for this source.").font(TronTypography.body).foregroundStyle(Color.tronTextSecondary)
                }
            }
            .padding(24)
        }
        .id(page) // Each bounded page starts at the top, rather than inheriting the previous page's scroll.
        .tronScrollEdgeChrome()
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .onChange(of: text) { _, _ in page = 0 }
        .onChange(of: recordID) { _, _ in page = 0 }
        .onChange(of: revisionID) { _, _ in page = 0 }
        .onChange(of: reference) { _, _ in page = 0 }
    }

    private func state(for reference: KnowledgeObjectRef) -> KnowledgeObjectReaderState {
        readers.state(for: KnowledgeObjectSelectionKey(recordID: recordID, revisionID: revisionID, reference: reference))
    }

    @ViewBuilder private func pagedText(_ value: String) -> some View {
        let count = value.count
        let start = min(page * pageSize, count)
        let end = min(start + pageSize, count)
        let first = value.index(value.startIndex, offsetBy: start)
        let last = value.index(value.startIndex, offsetBy: end)
        Text(value[first..<last])
            .font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Previous") { page = max(0, page - 1) }.disabled(page == 0)
            Spacer()
            Text("Page \(page + 1) of \(max(1, (count + pageSize - 1) / pageSize))").font(TronTypography.caption)
            Spacer()
            Button("Next") { page += 1 }.disabled(end >= count)
        }
        .buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
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
    @State private var objectReaders = KnowledgeObjectReaderStore()
    @State private var linkedReader = KnowledgeLinkedRecordReaderStore()
    @State private var citationTitles: [String: String] = [:]
    @State private var detailPreviewImage: UIImage?
    @State private var detailPreviewTicket = UUID()
    @State private var readerPresented = false
    @State private var readerReference: KnowledgeObjectRef?
    @State private var readerText: String?
    @State private var readerLabel = "saved text"
    private var admitsOrigin: Bool { model.knowledgePresentationIdentity == origin && activity.allowsPresentationPublication }
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
                    sourceLink
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
            detailPreviewImage = nil; detailPreviewTicket = UUID(); let ticket = detailPreviewTicket
            let requestIdentity = model.knowledgePresentationIdentity
            let requestActivity = activity
            guard case .source(let source) = currentRecord.content, let reference = source.preview,
                  requestIdentity == origin, requestActivity.allowsPresentationPublication else { return }
            guard let response = try? await model.knowledge.readObject(reference, recordID: currentRecord.id, revisionID: currentRecord.revisionId),
                  !Task.isCancelled, ticket == detailPreviewTicket, model.knowledgePresentationIdentity == requestIdentity,
                  requestActivity.allowsPresentationPublication,
                  response.offset == 0, response.nextOffset == nil, let data = Data(base64Encoded: response.base64),
                  data.count == response.bytes, response.totalBytes == response.bytes, data.count <= 512_000,
                  let image = await KnowledgePreviewDecoder.downsample(data), !Task.isCancelled,
                  ticket == detailPreviewTicket, model.knowledgePresentationIdentity == requestIdentity,
                  requestActivity.allowsPresentationPublication else { return }
            detailPreviewImage = image
        }
        .tronNavigationTitle(observationPresentation == nil ? "Knowledge detail" : "Observation", accent: .tronKnowledge)
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
        .tronManagedSheet(isPresented: $readerPresented, identity: "knowledge.reader.\(currentRecord.id)") {
            KnowledgeSavedTextReader(text: readerText, reference: readerReference, recordID: currentRecord.id, revisionID: currentRecord.revisionId, label: readerLabel, readers: objectReaders, loadNext: { reference, offset in readObject(reference, offset: offset) })
        }
        .tronManagedSheet(isPresented: $technicalDetailsSheet, identity: "knowledge.technical.\(currentRecord.id)") {
            if let observation = observationPresentation {
                KnowledgeObservationTechnicalDetailsSheet(presentation: observation)
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
        .onDisappear { objectReaders.suspend(); linkedReader.suspend() }
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
    private func sourceDetailHeader(_ source: KnowledgeSourceContent) -> some View {
        TronSettingsGroup("Source", accent: .tronKnowledge) {
            HStack(alignment: .top, spacing: TronSpacing.md) {
                Group {
                    if let detailPreviewImage { Image(uiImage: detailPreviewImage).resizable().scaledToFill().frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                    else { KnowledgeSourceThumbnail(source: source, size: 76) }
                }
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    Text(source.title)
                        .font(TronTypography.largeTitle)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let domain = KnowledgeSourcePresentationPolicy.domain(source.uri) {
                        Label(domain, systemImage: "globe")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronKnowledgeText)
                    }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder private var sourceLink: some View {
        if case .source(let source) = currentRecord.content {
            if let uri = source.uri, let url = KnowledgeSourcePresentationPolicy.safeURL(uri) {
                HStack(spacing: TronSpacing.lg) {
                    Link(destination: url) { Label("Open original", systemImage: "safari") }
                }
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronKnowledgeText)
            }
            if let summary = KnowledgeSourcePresentationPolicy.summary(source) {
                TronSettingsGroup("At a glance", accent: .tronKnowledge) {
                    Text(summary)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
            } else {
                TronSettingsGroup("At a glance", accent: .tronKnowledge) {
                    VStack(alignment: .leading, spacing: TronSpacing.sm) {
                        Text("No summary yet")
                            .font(TronTypography.bodySM.bold())
                        Text("No summary is generated automatically. Generate one from the saved evidence when you want an explicit interpretation.")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                        Button("Generate summary", systemImage: "sparkles") { triage() }
                            .buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
                            .disabled(mutationInFlight)
                    }
                    .padding(14)
                }
            }
            DisclosureGroup {
                savedTextAction(source)
            } label: {
                Label("Read saved text", systemImage: "text.alignleft")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .tronScrollSurface(accent: .tronKnowledge, tintOpacity: 0.06)
            if !currentRecord.provenance.evidence.isEmpty {
                DisclosureGroup {
                    citationLinks(Array(Dictionary(grouping: currentRecord.provenance.evidence, by: { "\($0.recordId ?? "")|\($0.revisionId ?? "")|\($0.locator ?? "")" }).values.compactMap { $0.first }))
                        .padding(.top, 8)
                } label: { Label("Found in related sources", systemImage: "link") }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .tronScrollSurface(accent: .tronKnowledge, tintOpacity: 0.06)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: TronSpacing.sm) {
                    if let origin = source.origins?.last ?? source.origin.flatMap({ value in KnowledgeSourceOriginKind(rawValue: value).map { KnowledgeSourceOrigin(kind: $0, capturedAt: source.capturedAt, annotation: nil, uri: source.uri, identity: source.identity) } }) {
                        Text("Saved from \(origin.kind.rawValue.capitalized) on \(humanDate(origin.capturedAt)).")
                        if let annotation = origin.annotation { Text(annotation).foregroundStyle(Color.tronTextSecondary) }
                    } else {
                        Text("Saved on \(humanDate(source.capturedAt)).")
                    }
                    if let reason = plainLanguageLimitation(source) { Text(reason).foregroundStyle(Color.tronTextSecondary) }
                    DisclosureGroup("Technical details") {
                        technicalSourceDetails(source)
                    }
                }
                .font(TronTypography.secondaryDescription)
                .padding(.top, 8)
            } label: {
                Label("About this source", systemImage: "info.circle")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .tronScrollSurface(accent: .tronKnowledge, tintOpacity: 0.06)
        }
    }

    @ViewBuilder private func savedTextAction(_ source: KnowledgeSourceContent) -> some View {
        if let text = source.text, !text.isEmpty {
            Button("Open saved text") {
                readerText = text; readerReference = nil; readerLabel = "saved text"; readerPresented = true
            }
            .buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
            Text("Saved readable text is separate from the original evidence file.")
                .font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
        } else {
            Text("No readable text was saved. The original reference and any retained evidence remain available in Technical details.")
                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
        }
    }

    @ViewBuilder private func technicalSourceDetails(_ source: KnowledgeSourceContent) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Text("Capture: \(source.captureDisposition.rawValue)")
            if let object = source.object { objectReader(object, label: "raw source") }
            if let representations = source.representations, !representations.isEmpty {
                ForEach(Array(representations.enumerated()), id: \.offset) { _, representation in
                    objectReader(representation.object, label: representation.kind == .providerAPI ? "provider data" : "retained representation")
                }
            }
            if let annotations = source.annotations, !annotations.isEmpty {
                Text("Annotations").font(TronTypography.bodySM.bold())
                ForEach(Array(annotations.prefix(10).enumerated()), id: \.offset) { _, annotation in
                    Text(annotation.text).font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                }
            }
            if let identity = source.identity { Text("Origin identity: \(identity.provider) · \(identity.itemId)").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary) }
        }
        .font(TronTypography.caption)
        .foregroundStyle(Color.tronTextSecondary)
        .padding(.top, 8)
    }

    private func plainLanguageLimitation(_ source: KnowledgeSourceContent) -> String? {
        switch source.captureDisposition {
        case .complete: return nil
        case .partial: return "Only the available portion was saved; replies, media, or linked pages may be missing."
        case .metadataOnly: return "Only page or media details were available; readable content was not captured."
        case .inaccessible, .failed, .referenceOnly: return "The original could not be fully read, so this reference is kept without claiming complete content."
        }
    }

    private func humanDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); guard let date = formatter.date(from: value) else { return value }
        let output = DateFormatter(); output.dateStyle = .medium; output.timeStyle = .none; return output.string(from: date)
    }

    @ViewBuilder private func objectReader(_ reference: KnowledgeObjectRef, label: String) -> some View {
        let key = KnowledgeObjectSelectionKey(recordID: currentRecord.id, revisionID: currentRecord.revisionId, reference: reference)
        let state = objectReaders.state(for: key)
        Button(state.bytes.isEmpty ? "Open \(label) (\(reference.bytes) bytes)" : "Load \(label)") {
            readerText = nil; readerReference = reference; readerLabel = label; readerPresented = true; readObject(reference, offset: state.nextOffset ?? 0)
        }
        .buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
        .disabled(state.loading || (state.nextOffset == nil && !state.bytes.isEmpty))
        if state.loading { TronLoadingState(label: "Loading \(label)…", accent: .tronKnowledge) }
        if let error = state.error { Text(error).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronAmber).fixedSize(horizontal: false, vertical: true) }
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
    private func readObject(_ reference: KnowledgeObjectRef, offset: Int) {
        guard admitsOrigin else { evidenceMessage = "Gateway changed; reopen this entry."; return }
        let key = KnowledgeObjectSelectionKey(recordID: currentRecord.id, revisionID: currentRecord.revisionId, reference: reference)
        let requestIdentity = origin
        let includeArchived: Bool = {
            guard case .source(let source) = currentRecord.content else { return false }
            return source.admission?.status == .archived
        }()
        Task { @MainActor in
            await objectReaders.load(key, offset: offset,
                request: { reference, offset in
                    try await model.knowledge.readObject(reference, recordID: currentRecord.id, revisionID: currentRecord.revisionId, includeArchived: includeArchived, offset: offset)
                },
                isCurrent: { model.knowledgePresentationIdentity == requestIdentity && activity.allowsPresentationPublication })
        }
    }
    private func loadCitationTitles() async {
        let refs = currentRecord.provenance.evidence + {
            if case .observation(let observation) = currentRecord.content { return observation.items.flatMap { $0.evidence ?? [] } }
            if case .note(let note) = currentRecord.content { return note.contraryEvidence ?? [] }
            return []
        }()
        for ref in refs.prefix(24) {
            guard !Task.isCancelled, model.knowledgePresentationIdentity == origin, activity.allowsPresentationPublication else { return }
            guard let id = ref.recordId, id != currentRecord.id else { continue }
            let key = ref.revisionId.map { "\(id)|\($0)" } ?? id
            guard citationTitles[key] == nil else { continue }
            let record = try? await model.knowledge.read(id: id, revisionID: ref.revisionId)
            guard !Task.isCancelled, model.knowledgePresentationIdentity == origin, activity.allowsPresentationPublication else { return }
            guard let record else { continue }
            let title: String
            switch record.content {
            case .source(let source): title = source.title
            case .observation(let observation): title = observation.items.first?.text ?? "Observation"
            case .note(let note): title = note.title
            }
            citationTitles[key] = title.isEmpty ? "Related source" : title
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
    private func triage() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { let result = try await model.knowledge.triage(sourceID: currentRecord.id, expectedRevision: currentRecord.revisionId); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; currentRecord = result.source; mutationInFlight = false; message = "Assessment updated (\(result.assessment.freshness.rawValue))." } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
    private func saveNote(_ note: KnowledgeNoteContent) { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { let result = try await model.knowledge.updateNote(id: currentRecord.id, expectedRevision: currentRecord.revisionId, record: KnowledgeRecordDraft(id: currentRecord.id, createdAt: currentRecord.createdAt, updatedAt: nil, kind: .note, scope: currentRecord.scope, provenance: currentRecord.provenance, temporal: currentRecord.temporal, relations: currentRecord.relations, importOrigin: currentRecord.importOrigin, content: .note(KnowledgeNoteContent(title: note.title, body: noteBody, fields: note.fields, role: note.role, confirmed: note.confirmed, contraryEvidence: note.contraryEvidence, freshness: note.freshness, privacyScope: note.privacyScope, usageConstraint: note.usageConstraint))), confirmedByUser: note.confirmed); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; currentRecord = result.record; mutationInFlight = false; message = "Saved"; await onChanged() } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
    private func exclude() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { _ = try await model.knowledge.setExclusion(recordID: currentRecord.id, expectedRevision: currentRecord.revisionId, excluded: true); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; dismiss() } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
    private func forget() { guard admitsOrigin else { message = "Gateway changed; reopen this entry."; return }; guard !mutationInFlight else { return }; mutationInFlight = true; let requestIdentity = origin; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { _ = try await model.knowledge.forget(id: currentRecord.id, expectedRevision: currentRecord.revisionId, reason: "Forgotten from iOS"); guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; dismiss() } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { mutationInFlight = false }; return } catch { guard model.knowledgePresentationIdentity == requestIdentity, activity.allowsPresentationPublication else { return }; mutationInFlight = false; message = error.localizedDescription } } }
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

struct KnowledgeConnectorsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var identity: KnowledgePresentationIdentity?
    @State private var integrationSnapshot: IntegrationSnapshot?
    @State private var statuses: [String: KnowledgeConnectorStatus] = [:]
    @State private var configuring: String?
    @State private var message: String?
    @State private var refreshGeneration: [String: Int] = [:]
    @State private var refreshInFlight = Set<String>()
    @State private var runInFlight = Set<String>()
    private var instances: [IntegrationInstance] { integrationSnapshot?.instances.filter { $0.definitionId == "knowledge.raindrop" || $0.definitionId == "knowledge.x" } ?? [] }
    var body: some View {
        KnowledgeFormSheet(title: "Connectors") {
            if instances.isEmpty {
                TronSettingsNotice(message: "Set up a Raindrop or X account in Settings > Integrations. Knowledge actions become available after that owner admits the account.", accent: .tronAmber)
            }
            ForEach(instances) { instance in
                let connector = instance.definitionId.replacingOccurrences(of: "knowledge.", with: "")
                let status = statuses[instance.id]
                TronSettingsGroup(connector == "x" ? "X" : "Raindrop", accent: .tronKnowledge) {
                    TronSettingsRow(icon: "person.crop.circle", title: instance.providerAccountId,
                                    subtitle: status.map { $0.configured ? ($0.enabled ? ($0.available ? "Enabled" : "Awaiting provider admission") : "Disabled") : "Not configured" } ?? "Checking status…") {
                        Button { configuring = instance.id } label: { TronInlineActionLabel("Configure") }.buttonStyle(.plain)
                    }
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronSettingsRow(icon: "arrow.clockwise", title: "Status") {
                        Button { refresh(instance) } label: { TronInlineActionLabel("Refresh") }.buttonStyle(.plain)
                            .disabled(refreshInFlight.contains(instance.id))
                    }
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronSettingsRow(icon: "arrow.triangle.2.circlepath", title: "Sync", subtitle: "Run using the saved permissions.") {
                        Button { run(instance) } label: { TronInlineActionLabel(runInFlight.contains(instance.id) ? "Running…" : "Run") }.buttonStyle(.plain)
                            .disabled(status?.configured != true || runInFlight.contains(instance.id))
                    }
                }
                .tronSettingsCaption(status?.writesEnabled == false ? "Remote writes are disabled." : nil)
                if let detail = status?.detail { TronSettingsNotice(message: detail, accent: .tronAmber) }
            }
            if let message { TronSettingsCaption(message) }
        }
        .task(id: PresentationActivityTaskID(source: "\(model.knowledgePresentationIdentity)", presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else { return }
            loadInstances()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            if !active {
                // Reads retire with their surface; accepted connector runs do not.
                for instance in instances { refreshGeneration[instance.id, default: 0] &+= 1 }
                refreshInFlight.removeAll()
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { configuring != nil }, set: { if !$0 { configuring = nil } }), identity: "knowledge.connector.edit") {
            if let instanceID = configuring, let instance = instances.first(where: { $0.id == instanceID }) {
                KnowledgeConnectorEditView(instance: instance, status: statuses[instanceID]) { configuring = nil }.environment(model)
            }
        }
    }
    private func loadInstances() {
        guard activity.allowsPresentationPublication else { return }
        let requestIdentity = model.knowledgePresentationIdentity
        Task { @MainActor in
            do {
                let loaded = try await model.integrations.snapshot()
                guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
                integrationSnapshot = loaded
                for instance in loaded.instances where instance.definitionId == "knowledge.raindrop" || instance.definitionId == "knowledge.x" { refresh(instance) }
            } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription }
        }
    }
    private func refresh(_ instance: IntegrationInstance) {
        guard activity.allowsPresentationPublication, !refreshInFlight.contains(instance.id) else { return }
        refreshInFlight.insert(instance.id)
        let requestIdentity = model.knowledgePresentationIdentity
        let ticket = (refreshGeneration[instance.id] ?? 0) &+ 1
        refreshGeneration[instance.id] = ticket
        let connector = instance.definitionId.replacingOccurrences(of: "knowledge.", with: "")
        Task { @MainActor in
            guard ticket == refreshGeneration[instance.id], activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let status = try await model.knowledge.connectorStatus(connector, connectionID: instance.id)
                guard ticket == refreshGeneration[instance.id], activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                identity = requestIdentity; statuses[instance.id] = status; refreshInFlight.remove(instance.id)
            } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { refreshInFlight.remove(instance.id) }; return }
            catch {
                guard ticket == refreshGeneration[instance.id], activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                refreshInFlight.remove(instance.id); statuses[instance.id] = nil; message = error.localizedDescription
            }
        }
    }
    private func run(_ instance: IntegrationInstance) {
        guard let status = statuses[instance.id], status.configured, activity.allowsPresentationPublication, !runInFlight.contains(instance.id) else { return }
        runInFlight.insert(instance.id)
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        let connector = instance.definitionId.replacingOccurrences(of: "knowledge.", with: "")
        Task { @MainActor in
            guard model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let result = try await model.knowledge.runConnector(connector, connectionID: instance.id, dryRun: false)
                guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
                runInFlight.remove(instance.id); message = result.error ?? "Run accepted (\(result.pending) pending)."
            } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { runInFlight.remove(instance.id) }; return }
            catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; runInFlight.remove(instance.id); message = error.localizedDescription }
        }
    }
}

private struct KnowledgeConnectorEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let instance: IntegrationInstance
    let status: KnowledgeConnectorStatus?
    let onSaved: () -> Void
    @State private var enabled: Bool
    @State private var destination: String
    @State private var allowWrites: Bool
    @State private var paidAccessApproved: Bool
    @State private var recurringApproved: Bool
    @State private var saving = false
    @State private var error: String?
    private var connector: String { instance.definitionId.replacingOccurrences(of: "knowledge.", with: "") }
    init(instance: IntegrationInstance, status: KnowledgeConnectorStatus?, onSaved: @escaping () -> Void) {
        self.instance = instance; self.status = status; self.onSaved = onSaved
        _enabled = State(initialValue: instance.policy.enabled); _destination = State(initialValue: status?.destination ?? ""); _allowWrites = State(initialValue: instance.policy.allowWrites); _paidAccessApproved = State(initialValue: instance.policy.paidAccessApproved); _recurringApproved = State(initialValue: instance.policy.recurringApproved)
    }
    var body: some View {
        KnowledgeFormSheet(title: connector == "x" ? "X connector" : "Raindrop connector", isWorking: saving, onAction: save) {
            TronSettingsGroup("Account", accent: .tronKnowledge) {
                TronSettingsRow(icon: "person.crop.circle", title: "Account", subtitle: instance.providerAccountId)
                if let scope = status?.scope ?? instance.scope {
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronSettingsRow(icon: "folder", title: connector == "raindrop" ? "Collection" : "User", subtitle: scope)
                }
                TronSettingsDivider(accent: .tronKnowledge)
                TronToggleRow(icon: "power", title: "Enabled", isOn: $enabled)
            }
            .tronSettingsCaption("Account identity and credentials are set up in Settings > Integrations. This view changes Knowledge policy only.")
            if connector == "raindrop" {
                TronSettingsGroup("Remote policy", accent: .tronKnowledge) {
                    TronTextSettingRow(icon: "folder.badge.plus", title: "Destination collection", detail: "Optional", value: $destination)
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronToggleRow(icon: "arrow.right.arrow.left", title: "Allow reversible moves", isOn: $allowWrites)
                }
                .tronSettingsCaption("Moves require a complete local capture and verified remote state.")
            }
            TronSettingsGroup("Access", accent: .tronKnowledge) {
                TronToggleRow(icon: "creditcard", title: "Paid access approved", isOn: $paidAccessApproved)
                TronSettingsDivider(accent: .tronKnowledge)
                TronToggleRow(icon: "repeat", title: "Recurring runs approved", isOn: $recurringApproved)
            }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
    }
    private func save() {
        guard !saving else { return }
        saving = true
        let requestIdentity = model.knowledgePresentationIdentity
        Task { @MainActor in
            do {
                _ = try await model.knowledge.configureConnector(connector, connectionID: instance.id, enabled: enabled, allowWrites: allowWrites, paidAccessApproved: paidAccessApproved, paidBudgetCents: instance.policy.paidBudgetCents, recurringApproved: recurringApproved, destination: destination.nilIfEmpty)
                guard activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                saving = false; onSaved(); dismiss()
            } catch is CancellationError {
                if model.knowledgePresentationIdentity == requestIdentity { saving = false }
            } catch let caught {
                guard activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                saving = false; error = caught.localizedDescription
            }
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct KnowledgeImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var source = "personal-os"
    @State private var plan: KnowledgeImportPlan?
    @State private var message: String?
    @State private var confirmExecute = false
    @State private var identity: KnowledgePresentationIdentity?
    @State private var offset = 0
    @State private var planOffset: Int?
    @State private var planSource: String?
    @State private var approvedPlanHash: String?
    @State private var importing = false
    @State private var progress: KnowledgeImportProgress?
    @State private var requestGeneration = 0
    var body: some View {
        KnowledgeFormSheet(title: "Import Knowledge") {
            TronSettingsGroup("Read-only inspection", accent: .tronKnowledge) {
                TronSelectionRow(icon: "externaldrive", title: "Named source", value: source == "personal-os" ? "Personal OS" : "LLM Wiki") {
                    Button("Personal OS") { source = "personal-os" }
                    Button("LLM Wiki") { source = "llm-wiki" }
                }
                .disabled(importing)
                TronSettingsDivider(accent: .tronKnowledge)
                TronSettingsRow(icon: "doc.text.magnifyingglass", title: "Import plan") {
                    Button { offset = 0; dryRun(offset: 0) } label: { TronInlineActionLabel("Inspect") }.buttonStyle(.plain).disabled(importing)
                }
            }
            .tronSettingsCaption("Only a deliberately configured named root on this Gateway can be read. Inspection does not import records.")
            if let plan, planOffset == offset, planSource == source {
                TronSettingsGroup("Inspected import plan", accent: .tronKnowledge) {
                    TronSettingsRow(icon: "chart.bar", title: "Progress") {
                        Text(progress.map { "\($0.completed) of \($0.total)" } ?? "0 of \(plan.planned)").font(TronTypography.secondaryCodeDescription)
                    }
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronSettingsRow(icon: "exclamationmark.triangle", title: "Warnings") { Text("\(plan.warnings.count)").font(TronTypography.secondaryCodeDescription) }
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronSettingsRow(icon: "eye.slash", title: "Skipped or withheld") { Text("\(plan.skipped)").font(TronTypography.secondaryCodeDescription) }
                }
                Text("Plan hash: \(plan.planHash)").font(TronTypography.secondaryCodeDescription)
                    .foregroundStyle(Color.tronTextSecondary).textSelection(.enabled)
                Button(importing ? "Importing…" : (approvedPlanHash == plan.planHash ? "Continue import" : "Import accepted items")) {
                    if approvedPlanHash == plan.planHash { execute(plan) } else { confirmExecute = true }
                }
                .buttonStyle(TronActionButtonStyle(role: .primary, accent: .tronKnowledge)).disabled(importing)
            }
            if let message { TronSettingsCaption(message) }
        }
        .confirmationDialog("Execute this exact inspected import?", isPresented: $confirmExecute) {
            Button("Import", role: .destructive) { if let plan { execute(plan) } }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func dryRun(offset requestedOffset: Int, preservingApproval: Bool = false) {
        guard activity.allowsPresentationPublication else { return }
        requestGeneration &+= 1
        let request = requestGeneration
        let source = source
        let requestIdentity = model.knowledgePresentationIdentity
        offset = max(0, requestedOffset)
        plan = nil; planOffset = nil; planSource = nil; if !preservingApproval { approvedPlanHash = nil; progress = nil; importing = false }; confirmExecute = false
        Task { @MainActor in
            guard request == requestGeneration, model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let value = try await model.knowledge.importDryRun(source: source, limit: 50, offset: requestedOffset)
                guard request == requestGeneration, activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                guard !preservingApproval || approvedPlanHash == value.planHash else { importing = false; approvedPlanHash = nil; message = "The import plan or scope changed; inspect it again before continuing."; return }
                identity = requestIdentity; plan = value; planOffset = requestedOffset; planSource = source; progress = value.progress; message = nil
                if preservingApproval { execute(value, continuing: true) }
            } catch is CancellationError { return }
            catch { guard request == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; message = error.localizedDescription }
        }
    }
    private func execute(_ plan: KnowledgeImportPlan, continuing: Bool = false) {
        guard let plannedOffset = planOffset, planSource == source, plannedOffset == offset,
              activity.allowsPresentationPublication,
              model.knowledgePresentationIdentity == (identity ?? model.knowledgePresentationIdentity) else { message = "Gateway changed or this inspection is stale; inspect the source again."; return }
        guard !importing || continuing else { return }
        // The one confirmation admits the complete plan hash. The Gateway's
        // progress/checkpoint is authoritative on retries; iOS never advances
        // an offset past a failed item or asks for a routine page approval.
        approvedPlanHash = plan.planHash
        importing = true
        requestGeneration &+= 1
        let request = requestGeneration
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        let plannedSource = planSource ?? source
        Task { @MainActor in
            guard request == requestGeneration, model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let value = try await model.knowledge.importRun(source: plannedSource, planHash: plan.planHash, limit: max(plan.planned, plan.selected), offset: plannedOffset)
                guard request == requestGeneration, activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                progress = value.progress
                message = KnowledgeImportPresentationPolicy.completionMessage(plan: plan, result: value, offset: plannedOffset)
                if value.failed == 0, !value.completed, value.progress.remaining > 0 {
                    dryRun(offset: value.progress.completed, preservingApproval: true)
                } else {
                    importing = false
                }
            } catch is CancellationError {
                if model.knowledgePresentationIdentity == requestIdentity { importing = false }
            }
            catch {
                guard request == requestGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }
                importing = false; message = error.localizedDescription
            }
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
        let replacement = KnowledgeRecordDraft(id: record.id, createdAt: record.createdAt, updatedAt: nil, kind: record.kind, scope: record.scope, provenance: KnowledgeCorrectionPolicy.provenance(for: record), temporal: record.temporal, relations: record.relations, importOrigin: record.importOrigin, content: KnowledgeCorrectionPolicy.content(for: record, replacementText: text))
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
