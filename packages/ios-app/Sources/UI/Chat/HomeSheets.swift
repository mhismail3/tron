import SwiftUI
import TronMobileCore

enum HomeSheetDestination: Identifiable {
    case settings, model, context, memory, tasks, permissions
    case task(String), grant(HomeTaskPermissionsDTO.Request)
    case evidence(HomeMemoryEvidenceDTO)
    var id: String {
        switch self { case .settings: "settings"; case .model: "model"; case .context: "context"; case .memory: "memory"; case .evidence: "evidence"; case .tasks: "tasks"; case .permissions: "permissions"; case .task: "task"; case .grant: "grant" }
    }
    var title: String {
        switch self { case .settings: "Memory Settings"; case .model: "Memory Model"; case .context: "Home Context"; case .memory: "Home Memory"; case .evidence: "Exact Evidence"; case .tasks: "Home Tasks"; case .permissions: "Task Permissions"; case .task: "Task"; case .grant: "Grant Request" }
    }
    var initialQuery: HomeSheetReadQuery {
        switch self {
        case .tasks: .tasks(nil)
        case .task(let id): .task(id)
        case .permissions, .grant: .permissions
        case .settings, .model, .context: .status
        case .memory: .memory(nil)
        case .evidence(let source): .evidence(source, offset: 0)
        }
    }

    var isTaskSurface: Bool {
        switch self { case .tasks, .task, .permissions, .grant: true; default: false }
    }

}

/// A Home sheet the chat presents for one profile. Choosing another destination
/// for that profile replaces the open sheet; a different profile dismisses it.
struct HomeSheetRoute: Identifiable {
    let profileID: String
    let destination: HomeSheetDestination
    var id: String { "home.\(profileID).\(destination.id)" }
}

private struct HomeSheetRequest: Hashable {
    var id = UUID()
    let query: HomeSheetReadQuery
}

private struct HomeSheetTaskID: Hashable {
    let identity: HomeSheetReadIdentity?
    let active: Bool
    let request: HomeSheetRequest
}

/// Managed, body-free status inspection and bounded one-page browser. Evidence
/// gets a child lifetime; no browser projection is persisted or accumulated.
struct HomeSheet: View {
    let destination: HomeSheetDestination
    let profileID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var token
    @Environment(\.tronPresentationActivity) private var activity
    @State private var owner = HomeSheetReadOwner()
    @State private var request: HomeSheetRequest
    @State private var evidenceDestination: HomeSheetDestination?
    @State private var mutationFailure: String?

    init(destination: HomeSheetDestination, profileID: String) {
        self.destination = destination
        self.profileID = profileID
        _request = State(initialValue: HomeSheetRequest(query: destination.initialQuery))
    }

    private var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    private var models: [ModelSummary] {
        model.providerCatalog(for: .global)?.models.filter { $0.available && $0.virtual != true } ?? []
    }

    var body: some View {
        Group {
            // The standard progressive model link owns its NavigationStack and
            // Done control. Other Home destinations own their sheet chrome.
            if destination.isTaskSurface { HomeTaskSheet(destination: destination, profileID: profileID) }
            else if case .model = destination { sheetContent }
            else { NavigationStack { sheetContent } }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
        .onDisappear { owner.retire() }
    }

    private var sheetContent: some View {
        Group {
            if case .model = destination { content }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                        if let mutationFailure {
                            TronPlaceholderState(title: "Home change", detail: mutationFailure, icon: "exclamationmark.triangle")
                        }
                    }
                    .padding(18)
                }
            }
        }
        .tronScrollEdgeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { TronSheetTitle(title: destination.title, accent: .tronEmerald) }
            if destination.id != "model" {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronEmerald)
                    }.accessibilityLabel("Done").accessibilityIdentifier("home-sheet-done-\(destination.id)")
                }
            }
        }
        .task(id: HomeSheetTaskID(identity: identity, active: active, request: request)) {
            guard let identity, let coordinator else { owner.retire(); return }
            guard active else { owner.retireLoading(); return }
            let query = request.query
            let requestID = request.id
            await owner.load(requestID: requestID, identity: identity, coordinator: coordinator,
                             isCurrent: { self.identity == identity && self.request.id == requestID },
                             preserveInstalledFrame: destination.id == "model") {
                try await fetch(query: query, identity: identity, requestID: requestID)
            }
        }
        .tronManagedSheet(item: $evidenceDestination, identity: { "home.\(profileID).\($0.id)" }) { child in
            HomeSheet(destination: child, profileID: profileID)
        }
        .alert("Home change", isPresented: Binding(get: { mutationFailure != nil && destination.id == "model" },
                                                   set: { if !$0 { mutationFailure = nil } })) {
            Button("OK", role: .cancel) { mutationFailure = nil }
        } message: { Text(mutationFailure ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch owner.state {
        case .idle, .loading(_, nil):
            TronLoadingState(label: "Loading Home…").accessibilityIdentifier("home-sheet-loading")
        case .failed(_, let error):
            TronPlaceholderState(title: "Home could not be read", detail: error, icon: "exclamationmark.triangle",
                                 actionTitle: "Reload") { reload() }
        case .loaded(let read, let content), .loading(let read, .some(let content)):
            if read.identity == identity {
                switch content {
                case .status(let status):
                    if case .settings = destination { settings(status) }
                    else if case .model = destination { modelPicker(status) }
                    else { context(status.activation) }
                case .tasks, .task, .permissions: EmptyView()
                case .memory(let page): memory(page)
                case .evidence(let page): evidence(page)
                }
            } else { TronLoadingState(label: "Waiting for Home…") }
        }
    }

    private func fetch(query: HomeSheetReadQuery, identity: HomeSheetReadIdentity, requestID: UUID) async throws -> HomeSheetContent {
        let content = try await model.readHomeSheet(query, identity: identity, isCurrent: { self.request.id == requestID && self.active })
        if query == .status, destination.id == "settings" || destination.id == "model",
           model.providerCatalog(for: .global) == nil {
            _ = await model.refreshProviders(target: .global)
        }
        return content
    }

    private func reload() {
        request = HomeSheetRequest(query: destination.initialQuery)
    }

    private func settings(_ status: HomeStatusDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: .tronPurple) {
                TronSelectionSheetRow(icon: "cpu", title: "Memory model", detail: "Summarizes Home memory",
                    value: SessionModelSelectionPresentation.modelName(status.memory.model, catalog: models),
                    accessibilityLabel: "Memory model", accent: .tronPurple) {
                    HomeSheet(destination: .model, profileID: profileID)
                }
                .accessibilityIdentifier("home-memory-model-row")
                .accessibilityValue(SessionModelSelectionPresentation.modelName(status.memory.model, catalog: models))
            }
            if !status.memory.configured {
                Text("Choose a memory model before sending").font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary)
            }
            if models.isEmpty {
                TronPlaceholderState(title: "No available memory models", detail: "Register a physical model on this Gateway.",
                    icon: "cpu", actionTitle: "Reload") { reload() }
            }
            TronGlassCard(accent: .tronEmerald) {
                VStack(spacing: 0) {
                    TronSettingsRow(icon: "chart.bar", title: "Memory spend", subtitle: "Information only; not a limit", accent: .tronEmerald) {
                        Text(status.memory.spentTokens.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                            .font(TronTypography.secondaryCodeDescription)
                    }
                    if status.memory.paused == true || status.memory.blocked != nil || status.memory.reason != nil {
                        TronSettingsDivider(accent: .tronEmerald)
                        TronSettingsRow(icon: "exclamationmark.triangle", title: status.memory.paused == true ? "Memory paused" : "Memory blocked",
                            subtitle: status.memory.blocked ?? status.memory.reason ?? "New responses are blocked", accent: .tronEmerald)
                    }
                }
            }
            if model.homeMutations.hasUnresolvedCommand {
                Button("Check completion") { checkCompletion() }.buttonStyle(TronActionButtonStyle(expands: false))
            }
        }
    }

    private var modelSelectionAvailability: ModelSelectionAvailability {
        if model.homeMutations.hasUnresolvedCommand { return .blocked("Check the pending Home change first") }
        guard !model.homeMutations.isRunning,
              case .loaded(let read, .status) = owner.state,
              read.id == request.id, read.identity == identity else { return .applying }
        return .ready
    }

    private func modelPicker(_ status: HomeStatusDTO) -> some View {
        ModelPicker(selection: Binding(get: { status.memory.model }, set: { selectModel($0, status: status) }),
                    models: models, selectionAvailability: modelSelectionAvailability)
    }

    private func selectModel(_ selection: ModelRef?, status: HomeStatusDTO) {
        // Receipt retirement is not projection convergence. The installed read
        // must own the current intent before another model choice is admitted.
        guard modelSelectionAvailability.canSelect,
              case .loaded(_, .status(let current)) = owner.state, current.memory.model == status.memory.model,
              let selection, selection != current.memory.model, models.contains(where: { $0.ref == selection }),
              let identity, let coordinator, active,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        Task { @MainActor in
            do {
                try await model.performHomeControl(.configureMemory(selection), authority: authority)
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication else { return }
                mutationFailure = nil
                request = HomeSheetRequest(query: destination.initialQuery)
            } catch {
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication,
                      !(error is CancellationError) else { return }
                mutationFailure = error.localizedDescription
            }
        }
    }

    private func checkCompletion() {
        guard let identity, let coordinator, active,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        Task { @MainActor in
            do {
                try await model.checkHomeControlCompletion(authority: authority)
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication else { return }
                mutationFailure = nil; request = HomeSheetRequest(query: destination.initialQuery)
            } catch {
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication,
                      !(error is CancellationError) else { return }
                mutationFailure = error.localizedDescription
            }
        }
    }

    @ViewBuilder private func context(_ activation: HomeStatusDTO.Activation) -> some View {
        if !activation.available {
            TronPlaceholderState(title: "No activation context yet", detail: "Home has not prepared a response.", icon: "doc.text.magnifyingglass")
        } else {
            Text("Effective activation context").font(TronTypography.headline)
            Text("Bounded request metadata, not canonical SDK usage or message bodies.")
                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
            TronGlassCard(accent: .tronEmerald) {
                VStack(spacing: 0) {
                    metadataRow("Activation", value: activation.activationOpen == true ? "Open" : "Settled")
                    metadataRow("Effective context", value: activation.effectiveTokens.map { "\($0) tokens" } ?? "Not prepared")
                    metadataRow("Context window", value: activation.contextWindow.map { "\($0) tokens" } ?? "Unavailable")
                    metadataRow("Memory view", value: activation.viewLines.flatMap { lines in activation.viewBytes.map { "\(lines) lines · \($0) bytes" } } ?? "Not prepared")
                    if let entry = activation.activationStartEntryId { metadataRow("Start entry", value: entry) }
                    if let reason = activation.lastRefusalReason {
                        metadataRow("Refusal", value: reason)
                        if let detail = activation.lastRefusalDetail { metadataRow("Detail", value: detail) }
                    }
                }
            }
        }
    }

    private func metadataRow(_ title: String, value: String) -> some View {
        TronSettingsRow(icon: "info.circle", title: title, accent: .tronEmerald) {
            Text(value).font(TronTypography.secondaryCodeDescription).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func memory(_ page: HomeMemoryPageDTO) -> some View {
        if page.items.isEmpty {
            TronPlaceholderState(title: "No memory yet", detail: "Memory appears after Home admits conversation history.", icon: "brain")
        } else {
            Text("Summaries and projections, not exact evidence").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
            ForEach(page.items) { item in
                TronGlassCard(accent: .tronEmerald) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text([item.attribution.rawValue, item.timestamp].compactMap { $0 }.joined(separator: " · "))
                            .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                        if let summary = item.summary {
                            Text(summary.truncated ? "Memory summary · Truncated" : "Memory summary").font(TronTypography.bodySM)
                            Text(summary.text).font(TronTypography.body)
                        }
                        Text(item.projection.omitted ? "Memory projection · Omitted from view" : "Memory projection").font(TronTypography.bodySM)
                        Text(item.projection.text).font(TronTypography.body)
                        if !item.projection.omissions.isEmpty {
                            Text("Omissions: \(item.projection.omissions.joined(separator: ", "))")
                                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                        }
                        Text("\(item.evidence.sessionId) · \(item.evidence.entryId)")
                            .font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
                        Button("Exact evidence") { evidenceDestination = .evidence(item.evidence) }
                            .buttonStyle(TronActionButtonStyle(expands: false))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }
            if let next = page.nextCursor {
                Button("Next memory page") {
                    if let last = page.items.last {
                        request = HomeSheetRequest(query: .memory(.init(cursor: next, revision: page.revision, homeId: page.homeId, afterIndex: last.index)))
                    }
                }
                    .buttonStyle(TronActionButtonStyle(expands: false))
            }
            if case .memory(.some) = request.query { Button("First memory page") { reload() }.buttonStyle(TronActionButtonStyle(expands: false)) }
        }
    }

    private func evidence(_ page: HomeMemoryEvidencePageDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Canonical history · Exact evidence").font(TronTypography.headline)
            Text("Canonical history rendering, not raw JSONL or attachment bytes.").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
            Text("\(page.evidence.sessionId) · \(page.evidence.entryId)").font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
            Text("Characters \(page.offset)–\(page.offset + page.text.utf16.count) of \(page.totalCharacters)").font(TronTypography.secondaryDescription)
            Text(page.text).font(TronTypography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let previous = page.previousOffset {
                Button("Previous evidence page") { request = HomeSheetRequest(query: .evidence(page.evidence, offset: previous)) }.buttonStyle(TronActionButtonStyle(expands: false))
            }
            if let next = page.nextOffset {
                Button("Next evidence page") { request = HomeSheetRequest(query: .evidence(page.evidence, offset: next)) }.buttonStyle(TronActionButtonStyle(expands: false))
            }
        }
    }
}
