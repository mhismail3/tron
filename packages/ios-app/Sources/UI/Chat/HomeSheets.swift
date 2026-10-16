import SwiftUI
import TronMobileCore

enum HomeSheetDestination: Identifiable {
    case manage
    /// Memory browser: one chapter's memory when `sessionID` is set, else the whole view.
    case memory(sessionID: String?, chapterOrdinal: Int?)
    /// One summary line and the two halves it covers (read on open).
    case memorySummary(HomeMemoryViewDTO.Line, sessionID: String?)
    /// A memory message's detail. Its data came with the row, so it is never read again.
    case memoryItem(HomeMemoryItemDTO)
    case evidence(HomeMemoryEvidenceDTO, origin: HomeMemoryOrigin)
    case chapters
    /// The learned profile, and one item: shown from the row the Profile sheet already
    /// loaded, then re-read with the profile so a change made here shows at once.
    case profile
    case profileItem(HomeProfileListDTO.Item)
    /// One chapter's detail, from the row the Chapters sheet already loaded.
    case chapter(HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits)
    case tasks
    case task(String)
    case permissions
    case grant(HomeTaskPermissionsDTO.Request)

    var id: String {
        switch self {
        case .manage: "manage"
        case .memory: "memory"
        case .memorySummary: "memory-summary"
        case .memoryItem: "memory-item"
        case .evidence: "evidence"
        case .chapters: "chapters"
        case .chapter: "chapter"
        case .profile: "profile"
        case .profileItem: "profile-item"
        case .tasks: "tasks"
        case .task: "task"
        case .permissions: "permissions"
        case .grant: "grant"
        }
    }

    var title: String {
        switch self {
        case .manage: "Manage Home"
        case .memory, .memorySummary, .memoryItem: "Memory"
        case .evidence: "Exact Evidence"
        case .chapters, .chapter: "Chapters"
        case .profile, .profileItem: "Profile"
        case .tasks, .task: "Tasks"
        case .permissions, .grant: "Permissions"
        }
    }

    var initialQuery: HomeSheetReadQuery {
        switch self {
        case .manage: .manage
        case .memory(let sessionID, _): .memory(sessionID: sessionID, continuation: nil)
        case .memorySummary(let line, let sessionID): .memoryPart(sessionID: sessionID, line)
        // Carried by the destination and never loaded; see `loadsPage`.
        case .memoryItem, .chapter: .chapters
        case .evidence(let source, _): .evidence(source, offset: 0)
        case .chapters: .chapters
        case .profile, .profileItem: .profile
        case .tasks: .tasks(nil)
        case .task(let id): .task(id)
        case .permissions, .grant: .permissions
        }
    }

    var isTaskSurface: Bool {
        switch self { case .tasks, .task, .permissions, .grant: true; default: false }
    }

    var loadsPage: Bool {
        switch self { case .memoryItem, .chapter: false; default: true }
    }
}

/// The memory row an evidence page belongs to, shown in the evidence header.
struct HomeMemoryOrigin: Hashable, Sendable {
    let attribution: HomeMemoryItemDTO.Attribution
    let timestamp: String?
}

/// A Home control's admission, captured when the user taps it. A confirmation
/// covers its sheet, which then stops being active, so the confirmed command runs
/// under the identity and authority the tap admitted rather than re-reading them.
struct HomeControlAdmission {
    let identity: HomeSheetReadIdentity
    let coordinator: PresentationActivityCoordinator
    let authority: HomeMutationCoordinator.Authority
}

/// A Home sheet the chat presents for one profile. Choosing another destination
/// for that profile replaces the open sheet; the chat's route owner releases the
/// chat, and with it this sheet, when the selected profile changes.
struct HomeSheetRoute: Identifiable {
    let profileID: String
    /// The Home chat the sheet was opened from; Manage Home reads its session.
    let sessionID: String
    let destination: HomeSheetDestination
    var id: String { "home.\(profileID).\(destination.id)" }
}

struct HomeSheetRequest: Hashable {
    var id = UUID()
    let query: HomeSheetReadQuery
}

struct HomeSheetTaskID: Hashable {
    let identity: HomeSheetReadIdentity?
    let active: Bool
    let request: HomeSheetRequest
}

/// Managed, body-free status inspection and bounded one-page browser. Each
/// sub-sheet is a managed child with its own read owner and lifetime; no browser
/// projection is persisted or accumulated.
struct HomeSheet: View {
    let destination: HomeSheetDestination
    let profileID: String
    /// The Home chat the Manage Home sheet reads for its stats and model cards.
    var sessionID: String?
    /// Opens a chapter's transcript or a worker chat read-only: the chat's route
    /// owner stages the navigation and dismisses this sheet.
    var onOpenSession: ((String) -> Void)?
    /// Tells the presenting sheet that this one changed Home's data (a profile edit),
    /// so it re-reads when it is uncovered instead of keeping its installed page.
    var onChanged: (() -> Void)?
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @Environment(\.tronPresentationActivityCoordinator) var coordinator
    @Environment(\.tronPresentationSurfaceToken) var token
    @Environment(\.tronPresentationActivity) var activity
    @PresentationState var owner = HomeSheetReadOwner()
    @PresentationState var request: HomeSheetRequest
    #if HOSTED_TEST
    @Environment(\.hostedHomeActionProbe) private var hostedActionProbe
    #endif
    /// Rows present an existing Home sheet as a managed child, so each child keeps
    /// its own read owner and lifetime.
    @PresentationState var childDestination: HomeSheetDestination?
    /// The accent of the row that opened the child: its sheet title, Done and
    /// loading pulse take it through the shared settings visual theme (#925).
    @PresentationState private var childAccent: Color?
    /// A Home text opened whole (a chapter topic) in the shared document sheet.
    @PresentationState var reading: HomeTextReading?
    @Environment(\.tronSettingsVisualTheme) private var visualTheme
    /// Manage Home's open child only reads (Context, Memory, Chapters), so its return
    /// keeps the installed page instead of re-reading every row.
    @PresentationState private var returnsFromBrowsing = false
    @PresentationState private var showsTerminal = false
    @PresentationState var mutationFailure: String?
    @PresentationState var confirmingDisable = false
    @PresentationState var disableAdmission: HomeControlAdmission?
    @PresentationState private var sliderPresentation = ConfigurationSliderPresentation()
    /// The learned-profile edit state of a Profile or item sheet (HomeProfileSheets.swift).
    @PresentationState var profileEdit = HomeProfileEditState()

    init(destination: HomeSheetDestination, profileID: String, sessionID: String? = nil,
         onOpenSession: ((String) -> Void)? = nil, onChanged: (() -> Void)? = nil) {
        self.destination = destination
        self.profileID = profileID
        self.sessionID = sessionID
        self.onOpenSession = onOpenSession
        self.onChanged = onChanged
        _request = PresentationState(wrappedValue: HomeSheetRequest(query: destination.initialQuery))
    }

    var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    /// This sheet's family accent: the row that opened it, else Home's own green.
    var accent: Color { visualTheme?.accent ?? .tronEmerald }
    var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    var body: some View {
        Group {
            if destination.isTaskSurface {
                HomeTaskSheet(destination: destination, profileID: profileID, onOpenSession: onOpenSession)
            } else {
                NavigationStack { sheetContent }
            }
        }
        .tronTopBlur(.sheet)
        // Every Manage Home sheet opens at medium and drags to large, as Manage
        // Session's sub-sheets do (#799, #811).
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accent)
        .onPresentationRetire { owner.retire() }
    }

    private var sheetContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
                if let mutationFailure {
                    TronPlaceholderState(title: "Home change", detail: mutationFailure, icon: "exclamationmark.triangle")
                }
            }
            .padding(18)
            .environment(\.tronSettingsSecondaryTextSizeAdjustment, SessionSummaryTypography.metadataSizeAdjustment)
        }
        .tronScrollEdgeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .manage = destination {
                ToolbarItem(placement: .topBarLeading) {
                    SessionTerminalToolbarButton(
                        enabled: active && sessionID != nil
                            && model.gatewayInfo?.capabilities.contains("terminal.v1") == true,
                        identifier: "manage-home-terminal",
                        accent: accent
                    ) { showsTerminal = true }
                }
            }
            ToolbarItem(placement: .principal) { TronSheetTitle(title: destination.title, accent: accent) }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if let editor = sliderPresentation.session {
                        _ = sliderPresentation.beginClosing(editor)
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: accent)
                }
                .accessibilityLabel("Done")
                .accessibilityIdentifier("home-sheet-done-\(destination.id)")
            }
        }
        .tronConfigurationSliderHost(sliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignposts)
        .task(id: HomeSheetTaskID(identity: identity, active: active, request: request)) {
            guard destination.loadsPage else { return }
            guard let identity, let coordinator else { owner.retire(); return }
            guard active else { owner.retireLoading(); return }
            let query = request.query
            let requestID = request.id
            // Uncovering a sheet keeps its installed page: returning from a child is not a
            // new request (#911). Manage Home refreshes behind its frame only after a child
            // that can change Home (tasks, permissions, settings, terminal, a profile edit);
            // the Profile sheet only after its item sheet changed an item.
            if owner.holds(requestID: requestID, identity: identity) {
                if refreshesBehindChildren, !returnsFromBrowsing { /* refresh below */ } else {
                    returnsFromBrowsing = false
                    return
                }
            }
            await owner.load(requestID: requestID, identity: identity, coordinator: coordinator,
                             isCurrent: { self.identity == identity && self.request.id == requestID },
                             preserveInstalledFrame: destination.id == "manage") {
                try await fetch(query: query, identity: identity, requestID: requestID)
            }
        }
        .tronManagedSheet(isPresented: $showsTerminal, identity: "home.\(profileID).terminal") {
            if let sessionID { TerminalSheet(sessionID: sessionID) }
        }
        .tronManagedSheet(item: $childDestination, identity: { "home.\(profileID).\($0.id)" }) { child in
            HomeSheet(destination: child, profileID: profileID, sessionID: sessionID, onOpenSession: onOpenSession,
                      onChanged: { returnsFromBrowsing = false; onChanged?() })
                .tronSettingsVisualTheme(accent: childAccent ?? accent)
        }
        .tronManagedSheet(item: $reading, identity: { "home.\(profileID).reading.\($0.id)" }) { reading in
            HomeTextReader(reading: reading).tronSettingsVisualTheme(accent: accent)
        }
        #if HOSTED_TEST
        // Retains the mounted pause action so hosted journeys can invoke it after
        // a route replacement; the identity fences inside `perform` must refuse it.
        .onAppear { if case .manage = destination { hostedActionProbe?.pause = { perform(.pauseMemory) } } }
        #endif
    }

    @ViewBuilder private var content: some View {
        switch destination {
        case .memoryItem(let item): memoryDetail(item)
        case .chapter(let chapter, let limits): chapterDetail(chapter, limits: limits)
        case .profileItem(let item): profileItemDetail(loadedProfileItem(item))
        default:
            loadedContent
        }
    }

    @ViewBuilder private var loadedContent: some View {
        switch owner.state {
        case .idle, .loading(_, nil):
            TronSheetLoadingState(label: "Loading Home…", accent: accent)
        case .failed(_, let error):
            TronPlaceholderState(title: "Home could not be read", detail: error, icon: "exclamationmark.triangle",
                                 actionTitle: "Reload") { reload() }
        case .loaded(let read, let content), .loading(let read, .some(let content)):
            if read.identity == identity {
                switch content {
                case .manage(let manage): manageSheet(manage)
                case .chapters(let list): chapters(list)
                case .profile(let list): profile(list)
                case .memory(let view): memory(view)
                case .evidence(let page):
                    if case .evidence(_, let origin) = destination { evidenceSheet(page, origin: origin) }
                case .tasks, .task, .permissions: EmptyView()
                }
            } else {
                TronSheetLoadingState(label: "Waiting for Home…", accent: accent)
            }
        }
    }

    private func fetch(query: HomeSheetReadQuery, identity: HomeSheetReadIdentity, requestID: UUID) async throws -> HomeSheetContent {
        try await model.readHomeSheet(query, identity: identity, isCurrent: { self.request.id == requestID && self.active })
    }

    func reload() {
        request = HomeSheetRequest(query: destination.initialQuery)
    }

    /// Presents a managed child sheet; rows use this, not their own navigation.
    /// `rowAccent` is the presenting row's tint; without one the child keeps
    /// this sheet's accent, so a whole Home branch shares its row's color.
    func present(_ child: HomeSheetDestination, rowAccent: Color? = nil) {
        switch child {
        case .memory, .chapters, .profile, .profileItem: returnsFromBrowsing = true
        default: returnsFromBrowsing = false
        }
        childAccent = rowAccent
        childDestination = child
    }

    private var refreshesBehindChildren: Bool {
        switch destination { case .manage, .profile: true; default: false }
    }

    /// Reloads the destination's own read after a mutation changed it.
    func refreshAfterMutation() {
        request = HomeSheetRequest(query: destination.initialQuery)
    }

    /// Accepted domain commands keep the chat's authority rules: acquire once
    /// for the mounted profile, then let the coordinator own receipt resolution.
    func admitControl() -> HomeControlAdmission? {
        guard let identity, let coordinator, active,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return nil }
        return HomeControlAdmission(identity: identity, coordinator: coordinator, authority: authority)
    }

    func perform(_ command: HomeMutationCoordinator.Command) {
        guard let admission = admitControl() else { return }
        run(command, admission)
    }

    func run(_ command: HomeMutationCoordinator.Command, _ admission: HomeControlAdmission) {
        Task { @MainActor in
            do {
                try await model.performHomeControl(command, authority: admission.authority)
                guard self.identity == admission.identity,
                      admission.coordinator.activity(for: admission.identity.surfaceToken).allowsDataPublication else { return }
                mutationFailure = nil
                refreshAfterMutation()
            } catch {
                guard self.identity == admission.identity,
                      admission.coordinator.activity(for: admission.identity.surfaceToken).allowsDataPublication,
                      !(error is CancellationError) else { return }
                mutationFailure = error.localizedDescription
            }
        }
    }

    func checkCompletion() {
        guard let identity, let coordinator, active,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        Task { @MainActor in
            do {
                try await model.checkHomeControlCompletion(authority: authority)
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication else { return }
                mutationFailure = nil
                refreshAfterMutation()
            } catch {
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication,
                      !(error is CancellationError) else { return }
                mutationFailure = error.localizedDescription
            }
        }
    }
}

/// A Home text opened whole: a task brief or a chapter topic. It reuses the
/// shared document sheet the instructions readers use, with the chat's markdown
/// renderer, and takes the presenting sheet's accent.
struct HomeTextReading: Identifiable, Hashable {
    let id: String
    let title: String
    let text: String
}

struct HomeTextReader: View {
    let reading: HomeTextReading

    var body: some View {
        TronDocumentSheet(title: reading.title, detents: [.medium, .large]) {
            ScrollView {
                TronMarkdownView(text: reading.text, streaming: false)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("home-reading-text")
            }
            .tronScrollEdgeChrome()
        }
    }
}
