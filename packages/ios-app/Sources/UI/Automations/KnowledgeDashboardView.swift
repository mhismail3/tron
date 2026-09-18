import SwiftUI

/// Catalogue pagination is available only for list responses. Search responses
/// are intentionally bounded to one Gateway result page.
enum KnowledgeCatalogPaginationPolicy {
    static func admits(cursor: String?, search: String, loadingMore: Bool) -> Bool {
        cursor != nil && !loadingMore && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Dashboard rhythm. Catalogue rows pack closer than the section rhythm so a
/// long retained list stays scannable; section boundaries add their own inset.
enum KnowledgeDashboardLayout {
    static let recordSpacing: CGFloat = 8
    /// Height of the coverage overview, reserved while sizing full-height
    /// loading/empty/error states so they are not pushed past the viewport by a
    /// section that costs two short rows.
    static let coverageSectionReservedHeight: CGFloat = 136
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
    let onOpenDraft: @MainActor (KnowledgeRecord) -> Void
    let onOpenSession: @MainActor (String, String) -> Void
    @State private var records: [KnowledgeRecord] = []
    @State private var selected: KnowledgeRecord?
    @State private var selectedIdentity: KnowledgePresentationIdentity?
    @State private var pendingDetailAction: DetailAction?
    private enum DetailAction { case draft(KnowledgeRecord), session(String, String) }
    @State private var search = ""
    @State private var kind: KnowledgeRecordKind?
    @State private var scope: KnowledgeScope?
    @State private var loading = false
    @State private var error: String?
    @State private var nextCursor: String?
    @State private var loadingMore = false
    @State private var status: KnowledgeStatus?
    @State private var coverageStore = KnowledgeCoveragePresentationStore()
    @State private var clearingCoverageID: String?
    @State private var coverageMutationError: String?
    @State private var coverageSheet = false
    @State private var loadGeneration = 0
    @State private var connectorRefreshGeneration: [String: Int] = [:]
    @State private var configSheet = false
    @State private var connectorSheet = false
    @State private var importSheet = false
    @State private var captureSheet = false
    @State private var noteSheet = false
    @State private var showingFilters = false
    @State private var showingSearch = false

    private var filterSummary: String {
        let summary = [kind?.label, scope?.label].compactMap { $0 }.joined(separator: " · ")
        return summary.isEmpty ? "All knowledge" : summary
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: KnowledgeDashboardLayout.recordSpacing) {
                        if let status { coverageOverview(status) }
                        dashboardContent(minimumHeight: max(280, geometry.size.height - (status == nil ? 0 : KnowledgeDashboardLayout.coverageSectionReservedHeight) - 100))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    // The floating controls must never cover the last record or coverage action.
                    .padding(.bottom, 80)
                }
                .tronScrollEdgeChrome()
                .refreshable { await reload() }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            TronTopBlurOverlay(style: .dashboard)
            if showingSearch {
                TronSearchBar(text: $search, prompt: "Search Knowledge", accent: .tronKnowledge,
                              focusOnAppear: true, onClose: dismissSearch,
                              onFocusChange: { if !$0 { dismissSearch() } })
                    .padding(.horizontal, TronSpacing.section)
                    .padding(.vertical, 8)
            } else {
                HStack {
                    Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(TronIconButtonStyle(accent: .tronKnowledge, size: 56))
                        .accessibilityLabel("Search Knowledge")
                    Spacer(minLength: 12)
                    Menu {
                        Button("Capture URL", systemImage: "link.badge.plus") { captureSheet = true }
                        Button("New note", systemImage: "note.text.badge.plus") { noteSheet = true }
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(TronIconButtonStyle(accent: .tronKnowledge, size: 56))
                        .accessibilityLabel("Add Knowledge")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tronBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                DashboardModeMenuButton(mode: .knowledge, onSelect: onSelectDashboard)
                    .frame(width: 34, height: 34)
            }
            ToolbarItem(placement: .principal) {
                Text("Knowledge")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(Color.tronKnowledge)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Color.tronKnowledge)
                }
                .accessibilityLabel("Knowledge filters")
                .accessibilityValue(filterSummary)
                Menu {
                    Button("Observation configuration", systemImage: "eye") { configSheet = true }
                    Button("Connectors", systemImage: "arrow.triangle.2.circlepath") { connectorSheet = true }
                    Button("Capture URL", systemImage: "link.badge.plus") { captureSheet = true }
                    Button("New note", systemImage: "note.text.badge.plus") { noteSheet = true }
                    Button("Import legacy records", systemImage: "square.and.arrow.down") { importSheet = true }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Color.tronKnowledge) }
                    .accessibilityLabel("Knowledge actions")
            }
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
        .onChange(of: model.knowledgePresentationIdentity) { _, _ in
            // Retire both the visible page and any manually spawned page task;
            // the next task must carry the new Gateway identity from its start.
            loadGeneration += 1
            loadingMore = false
            coverageStore.reset()
            clearingCoverageID = nil; coverageMutationError = nil; coverageSheet = false
            records.removeAll(); selected = nil; selectedIdentity = nil; pendingDetailAction = nil
            nextCursor = nil; status = nil; error = nil
        }
        .tronManagedSheet(isPresented: $coverageSheet, identity: "knowledge.coverage", onDismiss: finishDetailDismissal) {
            coverageDetailSheet
        }
        .tronManagedSheet(isPresented: $showingFilters, identity: "knowledge.filters") {
            knowledgeFilterSheet
        }
        .tronManagedSheet(isPresented: $configSheet, identity: "knowledge.configuration") {
            KnowledgeConfigurationView().environment(model)
        }
        .tronManagedSheet(isPresented: $connectorSheet, identity: "knowledge.connectors") {
            KnowledgeConnectorsView().environment(model)
        }
        .tronManagedSheet(isPresented: $importSheet, identity: "knowledge.import") {
            KnowledgeImportView().environment(model)
        }
        .tronManagedSheet(isPresented: $captureSheet, identity: "knowledge.capture") {
            KnowledgeCaptureView { captureSheet = false; await reload() }.environment(model)
        }
        .tronManagedSheet(isPresented: $noteSheet, identity: "knowledge.note") {
            KnowledgeNoteCreateView { noteSheet = false; await reload() }.environment(model)
        }
        .task(id: "\(kind?.rawValue ?? "all")/\(scope?.rawValue ?? "all")/\(search)/\(activity.allowsPresentationPublication)/\(model.knowledgePresentationIdentity.profileID ?? "none")/\(model.knowledgePresentationIdentity.lifecycleGeneration ?? -1)/\(model.knowledgePresentationIdentity.connectionID ?? -1)") {
            guard activity.allowsPresentationPublication else { return }
            await reload()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            if !active { coverageStore.suspend() }
        }
        .onDisappear { coverageStore.suspend() }
    }

    private func dismissSearch() {
        search = ""
        showingSearch = false
    }

    @ViewBuilder
    private func dashboardContent(minimumHeight: CGFloat) -> some View {
        if loading && records.isEmpty {
            TronLoadingState(label: "Loading Knowledge…", accent: .tronKnowledge)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
        } else if let error {
            TronPlaceholderState(title: "Knowledge unavailable", detail: error,
                                 icon: "externaldrive.badge.xmark", accent: .tronKnowledge,
                                 actionTitle: "Retry", action: { Task { await reload() } })
                .frame(minHeight: minimumHeight)
        } else if records.isEmpty {
            let filtered = kind != nil || scope != nil || !search.isEmpty
            TronPlaceholderState(title: filtered ? "No matching Knowledge" : "No Knowledge yet",
                                 detail: filtered ? "Adjust your search or filters to see more records." : "Observations, links, and notes retained by this Gateway will appear here.",
                                 icon: filtered ? "line.3.horizontal.decrease.circle" : "book.closed", accent: .tronKnowledge)
                .frame(minHeight: minimumHeight)
        } else {
            // The catalogue header opens a new section, so it keeps the section
            // rhythm while the rows themselves pack tighter.
            Text(filterSummary).font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronKnowledge)
                .padding(.top, TronSpacing.md)
            ForEach(records) { record in
                Button {
                    selected = record
                    selectedIdentity = model.knowledgePresentationIdentity
                } label: { KnowledgeRecordRow(record: record) }
                    .buttonStyle(.plain)
            }
            if nextCursor != nil {
                Button(loadingMore ? "Loading…" : "Load more") { loadMore() }
                    .buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
                    .disabled(loadingMore)
                    .frame(maxWidth: .infinity)
                    .padding(.top, TronSpacing.md)
            }
        }
    }

    private var knowledgeFilterSheet: some View {
        TronDashboardFilterSheet(title: "Knowledge filters", accent: .tronKnowledge,
                                 detents: [.medium, .large], onDone: { showingFilters = false }) {
            TronDashboardFilterSectionTitle(title: "Type", detail: "Choose which retained records to browse.")
            TronDashboardFilterOption(title: "All types", selected: kind == nil, accent: .tronKnowledge,
                                      inactiveAccent: .tronSlate) { kind = nil }
            ForEach(KnowledgeRecordKind.allCases, id: \.self) { value in
                TronDashboardFilterOption(title: value.label,
                                          selected: kind == value, accent: .tronKnowledge,
                                          inactiveAccent: .tronSlate) { kind = value }
            }
            TronDashboardFilterSectionTitle(title: "Scope", detail: "Narrow results without losing the current type selection.")
            TronDashboardFilterOption(title: "All scopes", selected: scope == nil, accent: .tronKnowledge,
                                      inactiveAccent: .tronSlate) { scope = nil }
            ForEach(KnowledgeScope.allCases, id: \.self) { value in
                TronDashboardFilterOption(title: value.label,
                                          selected: scope == value, accent: .tronKnowledge,
                                          inactiveAccent: .tronSlate) { scope = value }
            }
        }
    }
    private func coverageOverview(_ status: KnowledgeStatus) -> some View {
        KnowledgeCoverageOverview(
            coverage: status.coverage,
            requiresGatewayUpdate: !supportsCoverageFilter,
            onOpen: openCoverageDetail
        )
    }

    /// The coverage list lives in its own detail sheet so the dashboard card
    /// stays an informational overview.
    @ViewBuilder private var coverageDetailSheet: some View {
        if let status {
            KnowledgeCoverageDetailSheet(
                coverage: status.coverage,
                cuts: coverageStore.cuts,
                showsInitialLoading: coverageStore.showsInitialLoading,
                loadingMore: coverageStore.loading,
                canLoadMore: coverageStore.nextCursor != nil,
                errorText: coverageStore.error,
                mutationErrorText: coverageMutationError,
                clearingCutID: clearingCoverageID,
                allowsActions: activity.allowsPresentationPublication,
                onOpenSession: { cut in stageCoverageNavigation(.session(cut.range.sessionId, cut.range.fromEntryId)) },
                onClear: { clearCoverage($0) },
                onLoadMore: loadMoreCoverage
            )
        }
    }

    /// Coverage is read by disposition. An older Gateway cannot filter the
    /// ledger, so the container reports that instead of listing the cuts that
    /// happen to sit in the first settled page.
    private var supportsCoverageFilter: Bool {
        model.gatewayInfo?.capabilities.contains(KnowledgeRPCClient.coverageFilterCapability) == true
    }

    private func coverageRequest(cursor: String?) async throws -> KnowledgeCoveragePage {
        try await model.knowledge.coverage(cursor: cursor, limit: 100,
            dispositions: KnowledgeCoveragePresentationPolicy.attentionDispositions)
    }

    private func loadMoreCoverage() {
        let identity = model.knowledgePresentationIdentity
        Task { @MainActor in
            await coverageStore.loadMore(identity: identity,
                request: coverageRequest,
                isCurrent: { activity.allowsPresentationPublication && model.knowledgePresentationIdentity == identity })
        }
    }

    private func clearCoverage(_ cut: KnowledgeObservationCoverage) {
        guard activity.allowsPresentationPublication, clearingCoverageID == nil else { return }
        let identity = model.knowledgePresentationIdentity
        clearingCoverageID = cut.id; coverageMutationError = nil
        Task { @MainActor in
            defer { if model.knowledgePresentationIdentity == identity { clearingCoverageID = nil } }
            guard model.knowledgePresentationIdentity == identity else { return }
            do {
                _ = try await model.knowledge.dismissCoverage(cut, capabilities: model.gatewayInfo?.capabilities ?? [])
                guard model.knowledgePresentationIdentity == identity, activity.allowsPresentationPublication else { return }
                await reload()
            } catch {
                guard model.knowledgePresentationIdentity == identity, activity.allowsPresentationPublication else { return }
                coverageMutationError = error.localizedDescription
            }
        }
    }

    private func reload() async {
        loadGeneration += 1; let generation = loadGeneration; let identity = model.knowledgePresentationIdentity
        guard activity.allowsPresentationPublication, identity.profileID != nil, identity.lifecycleGeneration != nil else { return }
        loading = true; error = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            async let loadedStatus = model.knowledge.status()
            let response: KnowledgeListResponse
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { response = try await model.knowledge.list(kind: kind, scope: scope, limit: 50) }
            else { let found = try await model.knowledge.search(query: search, kind: kind, scope: scope, limit: 50); response = KnowledgeListResponse(records: found.hits.map { $0.record }, nextCursor: nil, stateRevision: found.stateRevision) }
            let currentStatus = try await loadedStatus
            guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            records = response.records; nextCursor = response.nextCursor; status = currentStatus
            // A Gateway that cannot filter coverage by disposition must not be
            // asked for a page whose settled rows this container never lists.
            if supportsCoverageFilter {
                await coverageStore.load(identity: identity, expectedStateRevision: currentStatus.stateRevision ?? 0,
                    request: coverageRequest,
                    isCurrent: { generation == loadGeneration && activity.allowsPresentationPublication && model.knowledgePresentationIdentity == identity })
            } else {
                coverageStore.reset()
            }
            guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
        } catch is CancellationError { return } catch { guard generation == loadGeneration, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription }
    }
    private func loadMore() {
        guard KnowledgeCatalogPaginationPolicy.admits(cursor: nextCursor, search: search, loadingMore: loadingMore), let cursor = nextCursor else { return }
        loadingMore = true
        let generation = loadGeneration
        let query = search
        let requestedKind = kind
        let requestedScope = scope
        let identity = model.knowledgePresentationIdentity
        Task { @MainActor in
            defer { if generation == loadGeneration { loadingMore = false } }
            guard generation == loadGeneration, query == search, requestedKind == kind, requestedScope == scope,
                  activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }
            do {
                let page = try await model.knowledge.list(kind: requestedKind, scope: requestedScope, cursor: cursor, limit: 50)
                guard generation == loadGeneration, query == search, requestedKind == kind, requestedScope == scope,
                      activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity,
                      page.records.allSatisfy({ !records.contains($0) }) else { return }
                records.append(contentsOf: page.records); nextCursor = page.nextCursor
            } catch is CancellationError { return }
            catch { guard generation == loadGeneration, query == search, activity.allowsPresentationPublication, model.knowledgePresentationIdentity == identity else { return }; self.error = error.localizedDescription }
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

/// The catalogue row for one retained record. Dense by design: several of these
/// should fit on a phone screen, so the row keeps one type step below the
/// detail sheet and only the statement's leading lines.
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

    init(record: KnowledgeRecord, origin: KnowledgePresentationIdentity, onChanged: @escaping () async -> Void, onOpenDraft: @escaping (KnowledgeRecord) -> Void, onOpenSession: @escaping (String, String) -> Void) {
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
    private var admitsOrigin: Bool { model.knowledgePresentationIdentity == origin && activity.allowsPresentationPublication }
    private var observationPresentation: KnowledgeObservationPresentation? { KnowledgeObservationPresentation(record: currentRecord) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                if let observation = observationPresentation {
                    KnowledgeObservationStatement(presentation: observation)
                        .textSelection(.enabled)
                    observationEvidence(observation)
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
                    sourceLink
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
        .tronSettingsVisualTheme(accent: .tronKnowledge)
        .confirmationDialog("Forget this record?", isPresented: $forgetConfirmation) {
            Button("Forget", role: .destructive) { forget() }
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
                                onOpenDraft: onOpenDraft, onOpenSession: onOpenSession)
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
    @ViewBuilder private var sourceLink: some View {
        if case .source(let source) = currentRecord.content {
            if let uri = source.uri, let url = URL(string: uri) {
                Link(uri, destination: url)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronKnowledgeText)
                    .textSelection(.enabled)
            }
            if let object = source.object { objectReader(object, label: "retained source") }
            if let retention = source.retention {
                Text("Retention: \(retention.sensitivity) · evidence \(retention.evidenceAvailable ? "available" : "unavailable")")
                    .font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
            }
            if let representations = source.representations, !representations.isEmpty {
                TronSettingsGroup("Retained representations", accent: .tronKnowledge) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(representations.enumerated()), id: \.offset) { _, representation in
                            objectReader(representation.object, label: representation.kind == .providerAPI ? "provider API" : "linked article")
                        }
                    }
                    .padding(14)
                }
            }
            if let annotations = source.annotations, !annotations.isEmpty {
                TronSettingsGroup("Annotations and corrections", accent: .tronKnowledge) {
                    ForEach(Array(annotations.enumerated()), id: \.offset) { _, annotation in
                        Text(annotation.text).font(TronTypography.body).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).padding(14)
                    }
                }
            }
            if let identity = source.identity {
                Text("\(identity.provider) · account \(identity.accountId) · item \(identity.itemId)")
                    .font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextSecondary).textSelection(.enabled)
            }
            if let assessment = source.assessment {
                TronSettingsGroup("Assessment", accent: .tronKnowledge) {
                    VStack(alignment: .leading, spacing: TronSpacing.sm) {
                        Text(assessment.summary).font(TronTypography.body).foregroundStyle(Color.tronTextPrimary).fixedSize(horizontal: false, vertical: true)
                        if let contribution = assessment.contribution { Text("Contribution: \(contribution)").font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary) }
                        if let use = assessment.possibleUse { Text("Possible use: \(use)").font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary) }
                        Text("Evidence \(assessment.evidenceQuality.rawValue) · Freshness \(assessment.freshness.rawValue)").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                    }
                    .padding(14)
                }
            }
        }
    }
    @ViewBuilder private func objectReader(_ reference: KnowledgeObjectRef, label: String) -> some View {
        let key = KnowledgeObjectSelectionKey(recordID: currentRecord.id, revisionID: currentRecord.revisionId, reference: reference)
        let state = objectReaders.state(for: key)
        Button(state.bytes.isEmpty ? "Open \(label) (\(reference.bytes) bytes)" : "Load \(label)") {
            readObject(reference, offset: state.nextOffset ?? 0)
        }
        .buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
        .disabled(state.loading || (state.nextOffset == nil && !state.bytes.isEmpty))
        if state.loading { TronLoadingState(label: "Loading \(label)…", accent: .tronKnowledge) }
        if let error = state.error { Text(error).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronAmber).fixedSize(horizontal: false, vertical: true) }
        if !state.bytes.isEmpty {
            Text(KnowledgeObjectPresentationPolicy.renderedText(state.bytes, mediaType: reference.mediaType, label: label))
                .font(TronTypography.codeBlock).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled)
                .padding(TronSpacing.md).tronScrollSurface(accent: .tronKnowledge, tintOpacity: 0.06)
            if let next = state.nextOffset {
                Text("Loaded \(state.bytes.count) of \(state.totalBytes ?? reference.bytes) bytes.").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                Button("Load next \(label) chunk (offset \(next))") { readObject(reference, offset: next) }.buttonStyle(TronActionButtonStyle(expands: false, accent: .tronKnowledge))
            } else { Text("Complete \(label) loaded (\(state.bytes.count) bytes).").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary) }
        }
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
            } else if let recordID = ref.recordId {
                Button("Open record \(recordID) · revision \(ref.revisionId ?? "latest")") { openLinkedRecord(id: recordID, revisionID: ref.revisionId) }
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
        Task { @MainActor in
            await objectReaders.load(key, offset: offset,
                request: { reference, offset in
                    try await model.knowledge.readObject(reference, recordID: currentRecord.id, revisionID: currentRecord.revisionId, offset: offset)
                },
                isCurrent: { model.knowledgePresentationIdentity == requestIdentity && activity.allowsPresentationPublication })
        }
    }
    private func openLinkedRecord(id: String, revisionID: String?) {
        guard admitsOrigin else { evidenceMessage = "Gateway changed; reopen this entry."; return }
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
    @State private var selectedSessionIDs = Set<String>()
    @State private var selectedProjectIDs = Set<String>()
    @State private var interestsText = ""
    @State private var saving = false
    @State private var error: String?
    @State private var identity: KnowledgePresentationIdentity?
    private var observesAllConversations: Bool { config?.eligibility.allSessions == true }
    private var supportsGlobalObservation: Bool { model.gatewayInfo?.capabilities.contains(KnowledgeRPCClient.globalObservationCapability) == true }
    private var hasScope: Bool { observesAllConversations || !selectedSessionIDs.isEmpty || !selectedProjectIDs.isEmpty }
    private var canSave: Bool { config != nil }
    var body: some View {
        KnowledgeFormSheet(title: "Observation", isWorking: saving, actionDisabled: !canSave, onAction: save) {
            if config == nil && error == nil { TronLoadingState(label: "Loading configuration…") }
            TronSettingsGroup("Observer", accent: .tronKnowledge) {
                TronSelectionSheetRow(icon: "cpu", title: "Model", value: chosenModel?.id ?? "Choose", accent: .tronKnowledge) {
                    ModelPicker(selection: $chosenModel, models: model.providerCatalog(for: .global)?.models.filter(\.available) ?? [])
                        .tronNavigationTitle("Observation model", accent: .tronKnowledge)
                        .presentationDetents([.large])
                }
                TronSettingsDivider(accent: .tronKnowledge)
                TronToggleRow(icon: "eye", title: "Enable observation",
                              detail: "Save cited observations from future eligible conversation turns.", accent: .tronKnowledge,
                              isOn: Binding(get: { config?.observation.enabled ?? false }, set: { config?.observation.enabled = $0 }))
                    .disabled(config?.observation.enabled != true && (chosenModel == nil || !hasScope))
            }
            .disabled(config == nil)
            .tronSettingsCaption("Choose an existing configured model and an observation scope. Earlier turns are not backfilled.")
            TronSettingsGroup("Scope", accent: .tronKnowledge) {
                TronToggleRow(icon: "globe", title: "All Tron conversations",
                              detail: "Include future turns in every workspace on this Gateway. Excluded conversations and projects stay excluded.", accent: .tronKnowledge,
                              isOn: Binding(get: { observesAllConversations }, set: { config?.eligibility.allSessions = $0 ? true : nil }))
                    .disabled(config == nil || (!supportsGlobalObservation && !observesAllConversations))
            }
            .tronSettingsCaption("This covers Tron conversations, not other apps or files on your Mac. It does not select delegated-agent transcripts.")
            if !supportsGlobalObservation {
                TronSettingsNotice(message: "Update this Gateway to use all-conversation observation.", accent: .tronAmber)
            }
            TronSettingsGroup("Current interests", accent: .tronKnowledge, surfaceStyle: .uncontained) {
                TextEditor(text: $interestsText).frame(minHeight: 120).tronTextEditor()
                    .accessibilityLabel("Current interests")
            }
            .tronSettingsCaption("One interest per line, up to 50. Interests guide source triage and do not enable observation.")
            if !observesAllConversations {
                TronSettingsGroup("Selected conversations", accent: .tronKnowledge, surfaceStyle: model.sessions.isEmpty ? .uncontained : .scrollOptimized) {
                    if model.sessions.isEmpty { TronSettingsCaption("No sessions are available on this Gateway.") }
                    ForEach(model.sessions.prefix(100)) { session in
                        TronToggleRow(icon: "bubble.left.and.bubble.right", title: session.title, accent: .tronKnowledge,
                                      isOn: Binding(get: { selectedSessionIDs.contains(session.id) }, set: { if $0 { selectedSessionIDs.insert(session.id) } else { selectedSessionIDs.remove(session.id) } }))
                    }
                }
                TronSettingsGroup("Selected projects", accent: .tronKnowledge, surfaceStyle: .scrollOptimized) {
                    if let workspace = model.workspace {
                        ForEach(workspace.entries.filter { $0.kind == .directory }.prefix(100)) { entry in
                            TronToggleRow(icon: "folder", title: entry.name, accent: .tronKnowledge,
                                          isOn: Binding(get: { selectedProjectIDs.contains(entry.path) }, set: { if $0 { selectedProjectIDs.insert(entry.path) } else { selectedProjectIDs.remove(entry.path) } }))
                        }
                    }
                }
                .tronSettingsCaption("With all-conversation observation off, an empty selection means no eligible scope. Exclusions always win.")
            }
            if !hasScope { TronSettingsNotice(message: "No scope selected", accent: .tronAmber) }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
        .task { await load() }
    }
    private func load() async {
        let requestIdentity = model.knowledgePresentationIdentity
        do {
            let loaded = try await model.knowledge.status()
            guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity, requestIdentity.profileID != nil else { return }
            identity = requestIdentity; config = loaded.config; interestsText = loaded.config.currentInterests.joined(separator: "\n"); selectedSessionIDs = Set(loaded.config.eligibility.sessionIds); selectedProjectIDs = Set(loaded.config.eligibility.projectIds)
            if let value = loaded.config.observation.model { let parts = value.split(separator: "/", maxSplits: 1).map(String.init); if parts.count == 2 { chosenModel = ModelRef(provider: parts[0], id: parts[1]) } }
        } catch {
            guard activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestIdentity else { return }
            self.error = error.localizedDescription
        }
    }
    private func save() {
        guard !saving, var config else { return }
        guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == (identity ?? model.knowledgePresentationIdentity) else { error = "Gateway changed; reopen configuration."; return }
        if config.observation.enabled && (chosenModel == nil || !hasScope) { error = "Select a model and all conversations or at least one selected scope before enabling observation."; return }
        saving = true
        if let chosenModel { config.observation.model = chosenModel.contextWindowKey }
        config.eligibility.sessionIds = selectedSessionIDs.sorted(); config.eligibility.projectIds = selectedProjectIDs.sorted(); config.currentInterests = interestsText.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(50).map { String($0.prefix(500)) }
        let requestIdentity = identity ?? model.knowledgePresentationIdentity
        Task { @MainActor in
            guard model.knowledgePresentationIdentity == requestIdentity else { return }
            do { _ = try await model.knowledge.configure(config, capabilities: model.gatewayInfo?.capabilities ?? []); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; saving = false; dismiss() }
            catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { saving = false }; return }
            catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; saving = false; self.error = error.localizedDescription }
        }
    }
}

struct KnowledgeConnectorsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.dismiss) private var dismiss
    @State private var identity: KnowledgePresentationIdentity?
    @State private var statuses: [String: KnowledgeConnectorStatus] = [:]
    @State private var configuring: String?
    @State private var message: String?
    @State private var refreshGeneration: [String: Int] = [:]
    @State private var refreshInFlight = Set<String>()
    @State private var runInFlight = Set<String>()
    var body: some View {
        KnowledgeFormSheet(title: "Connectors") {
            ForEach(["raindrop", "x"], id: \.self) { connector in
                TronSettingsGroup(connector == "x" ? "X" : "Raindrop", accent: .tronKnowledge) {
                    TronSettingsRow(icon: "person.crop.circle", title: "Account",
                                    subtitle: statuses[connector].map { $0.configured ? ($0.enabled ? "Enabled" : "Disabled") : "Not configured" } ?? "Checking status…") {
                        Button { configuring = connector } label: { TronInlineActionLabel("Configure") }.buttonStyle(.plain)
                    }
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronSettingsRow(icon: "arrow.clockwise", title: "Status") {
                        Button { refresh(connector) } label: { TronInlineActionLabel("Refresh") }.buttonStyle(.plain)
                            .disabled(refreshInFlight.contains(connector))
                    }
                    TronSettingsDivider(accent: .tronKnowledge)
                    TronSettingsRow(icon: "arrow.triangle.2.circlepath", title: "Sync", subtitle: "Run using the saved permissions.") {
                        Button { run(connector) } label: { TronInlineActionLabel(runInFlight.contains(connector) ? "Running…" : "Run") }.buttonStyle(.plain)
                            .disabled(statuses[connector]?.configured != true || runInFlight.contains(connector))
                    }
                }
                .tronSettingsCaption(statuses[connector]?.writesEnabled == false ? "Remote writes are disabled." : nil)
                if let detail = statuses[connector]?.detail { TronSettingsNotice(message: detail, accent: .tronAmber) }
            }
            if let message { TronSettingsCaption(message) }
        }
        .task(id: PresentationActivityTaskID(source: "\(model.knowledgePresentationIdentity)", presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else { return }
            refresh("raindrop"); refresh("x")
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in
            if !active {
                // Reads retire with their surface; accepted connector runs do not.
                for connector in ["raindrop", "x"] { refreshGeneration[connector, default: 0] &+= 1 }
                refreshInFlight.removeAll()
            }
        }
        .tronManagedSheet(isPresented: Binding(get: { configuring != nil }, set: { if !$0 { configuring = nil } }), identity: "knowledge.connector.edit") {
            if let connector = configuring {
                KnowledgeConnectorEditView(connector: connector, status: statuses[connector]) { configuring = nil }.environment(model)
            }
        }
    }
    private func refresh(_ connector: String) {
        guard activity.allowsPresentationPublication, !refreshInFlight.contains(connector) else { return }
        refreshInFlight.insert(connector)
        let requestIdentity = model.knowledgePresentationIdentity
        let ticket = (refreshGeneration[connector] ?? 0) &+ 1
        refreshGeneration[connector] = ticket
        Task { @MainActor in
            guard ticket == refreshGeneration[connector], activity.allowsPresentationPublication,
                  model.knowledgePresentationIdentity == requestIdentity else { return }
            do {
                let status = try await model.knowledge.connectorStatus(connector)
                guard ticket == refreshGeneration[connector], activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                identity = requestIdentity; statuses[connector] = status; refreshInFlight.remove(connector)
            } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { refreshInFlight.remove(connector) }; return }
            catch {
                guard ticket == refreshGeneration[connector], activity.allowsPresentationPublication,
                      model.knowledgePresentationIdentity == requestIdentity else { return }
                refreshInFlight.remove(connector); statuses[connector] = nil; message = error.localizedDescription
            }
        }
    }
    private func run(_ connector: String) { guard let status = statuses[connector], status.configured, activity.allowsPresentationPublication, !runInFlight.contains(connector) else { return }; runInFlight.insert(connector); let requestIdentity = identity ?? model.knowledgePresentationIdentity; Task { @MainActor in guard model.knowledgePresentationIdentity == requestIdentity else { return }; do { let result = try await model.knowledge.runConnector(connector, dryRun: false); guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; runInFlight.remove(connector); message = result.error ?? "Run accepted (\(result.pending) pending)." } catch is CancellationError { if model.knowledgePresentationIdentity == requestIdentity { runInFlight.remove(connector) }; return } catch { guard activity.allowsPresentationPublication, model.knowledgePresentationIdentity == requestIdentity else { return }; runInFlight.remove(connector); message = error.localizedDescription } } }
}

private struct KnowledgeConnectorEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    let connector: String
    let status: KnowledgeConnectorStatus?
    let onSaved: () -> Void
    @State private var enabled: Bool
    @State private var accountID: String
    @State private var scope: String
    @State private var destination = ""
    @State private var credentialRef = ""
    @State private var allowWrites: Bool
    @State private var paidAccessApproved: Bool
    @State private var recurringApproved: Bool
    @State private var saving = false
    @State private var error: String?
    init(connector: String, status: KnowledgeConnectorStatus?, onSaved: @escaping () -> Void) {
        self.connector = connector; self.status = status; self.onSaved = onSaved
        _enabled = State(initialValue: status?.enabled ?? false); _accountID = State(initialValue: status?.accountId ?? ""); _scope = State(initialValue: status?.scope ?? ""); _allowWrites = State(initialValue: status?.allowWrites ?? false); _paidAccessApproved = State(initialValue: status?.paidAccessApproved ?? false); _recurringApproved = State(initialValue: status?.recurringApproved ?? false)
    }
    var body: some View {
        KnowledgeFormSheet(title: connector == "x" ? "X connector" : "Raindrop connector", isWorking: saving, onAction: save) {
            TronSettingsGroup("Account", accent: .tronKnowledge) {
                TronToggleRow(icon: "power", title: "Enabled", isOn: $enabled)
                TronSettingsDivider(accent: .tronKnowledge)
                TronTextSettingRow(icon: "person.crop.circle", title: "Account ID", value: $accountID)
                TronSettingsDivider(accent: .tronKnowledge)
                TronTextSettingRow(icon: "folder", title: connector == "raindrop" ? "Collection ID" : "User ID", value: $scope)
                TronSettingsDivider(accent: .tronKnowledge)
                TronSettingsRow(icon: "key", title: "Credential reference", subtitle: "Stored on your Mac") {
                    SecureField("Mac Keychain reference", text: $credentialRef).tronInlineField(monospaced: true)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .multilineTextAlignment(.trailing).frame(minWidth: 80, maxWidth: 180)
                        .accessibilityLabel("Mac Keychain reference")
                }
            }
            .tronSettingsCaption("Credentials stay in the Mac Keychain; this is only an opaque reference.")
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
                _ = try await model.knowledge.configureConnector(connector, enabled: enabled, accountID: accountID.nilIfEmpty, scope: scope.nilIfEmpty, destination: destination.nilIfEmpty, credentialRef: credentialRef.nilIfEmpty, allowWrites: allowWrites, paidAccessApproved: paidAccessApproved, recurringApproved: recurringApproved)
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
