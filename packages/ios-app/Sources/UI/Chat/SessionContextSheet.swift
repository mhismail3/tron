import SwiftUI

private enum ManageSessionDestination: String, Identifiable {
    case agentInstructions, projectResources, history, processHistory, terminal, workspace
    var id: String { rawValue }
}

enum SessionCompactionControlPolicy {
    enum VisualState: Equatable { case queued, inProgress, idle }

    static func visualState(
        compactionQueued: Bool,
        submitting: Bool,
        phase: SessionPhase
    ) -> VisualState {
        if compactionQueued { return .queued }
        if submitting || phase == .compacting { return .inProgress }
        return .idle
    }

    static func canRequest(
        phase: SessionPhase,
        operationKind: SessionOperationState.Kind? = nil,
        compactionQueued: Bool,
        submitting: Bool,
        exporting: Bool = false
    ) -> Bool {
        guard !submitting, !compactionQueued, !exporting else { return false }
        if phase == .running { return operationKind == .prompt }
        return phase == .idle || phase == .interrupted
    }

    static func automaticStatus(_ enabled: Bool?) -> String {
        switch enabled {
        case true: "Enabled"
        case false: "Disabled"
        case nil: "Unavailable"
        }
    }
}

enum SessionContextUsageRefreshPresentation: Equatable {
    case compacted
    case awaitingFirstResponse
    case awaitingRefresh

    init(lastTranscriptKind: TranscriptItem.Kind?, assistantMessages: Int) {
        if lastTranscriptKind == .compaction {
            self = .compacted
        } else if assistantMessages == 0 {
            self = .awaitingFirstResponse
        } else {
            self = .awaitingRefresh
        }
    }

    var detail: String {
        switch self {
        case .compacted:
            "Compacted to a fresh window. The next response will refresh the estimate."
        case .awaitingFirstResponse:
            "The first assistant response will provide the usage estimate."
        case .awaitingRefresh:
            "The next assistant response will refresh the usage estimate."
        }
    }
}

enum SessionExportPresentationPolicy {
    static func canStart(activeFormat: String?) -> Bool { activeFormat == nil }
    static func showsProgress(rowFormat: String, activeFormat: String?) -> Bool {
        rowFormat == activeFormat
    }

    static func title(for format: String) -> String {
        format == "jsonl" ? "Export as JSON" : "Export as HTML"
    }
}

enum SessionModelSelectionPresentation {
    static func displayed(pending: SessionPendingModelSelection?, authoritative: ModelRef?) -> ModelRef? {
        pending?.value ?? authoritative
    }

    static func reconciledPending(
        pending: SessionPendingModelSelection?,
        authoritative: ModelRef?,
        runtimeGeneration: String?
    ) -> SessionPendingModelSelection? {
        pending?.reconciled(authoritative: authoritative, runtimeGeneration: runtimeGeneration)
    }

    static func modelName(_ selection: ModelRef?, catalog: [ModelSummary]) -> String {
        guard let selection else { return "Choose model" }
        return catalog.first(where: { $0.ref == selection })?.displayName ?? selection.displayName
    }
}

enum SessionContextUsagePresentation: Equatable {
    case available(used: Int, window: Int, percent: Double)
    case unavailable

    init(_ usage: ContextUsage?) {
        guard let usage,
              let used = usage.tokens,
              let percent = usage.percent,
              usage.contextWindow > 0 else {
            self = .unavailable
            return
        }
        self = .available(
            used: max(0, used),
            window: usage.contextWindow,
            percent: min(max(percent, 0), 100)
        )
    }

    var usedSummary: String? {
        guard case .available(let used, let window, let percent) = self else { return nil }
        return "\(used.formatted(.number.notation(.compactName)))/\(window.formatted(.number.notation(.compactName))) • \(Int(percent.rounded()))% used"
    }

    var accessibilityLabel: String {
        switch self {
        case .available(let used, let window, let percent):
            let remaining = max(0, window - used)
            return "Context usage: \(Int(percent.rounded())) percent used, \(remaining.formatted(.number.notation(.compactName))) tokens left, \(used.formatted(.number.notation(.compactName))) used of \(window.formatted(.number.notation(.compactName)))"
        case .unavailable:
            return "Context usage: estimate pending, displayed as zero percent until fresh usage is reported"
        }
    }
}

enum SessionWorkspaceRowPresentation: Equatable {
    case loading
    case notRepository
    case loaded(branch: String, dirty: Bool, changeCount: Int)
    case failed(String)

    static func resolve(_ inspection: SessionWorkspaceInspection) -> SessionWorkspaceRowPresentation {
        guard let repository = inspection.repository else { return .notRepository }
        let branch: String
        if repository.unborn {
            branch = repository.branch ?? "Unborn branch"
        } else if let value = repository.branch, !value.isEmpty {
            branch = value
        } else if let head = repository.head {
            branch = "Detached · \(head.prefix(8))"
        } else {
            branch = "Detached HEAD"
        }
        return .loaded(branch: branch, dirty: repository.dirty, changeCount: repository.changes.count)
    }
}

private struct SessionWorkspaceRefreshIdentity: Hashable {
    let profileID: String
    let target: SessionPresentationIdentity
    let runtimeGeneration: String
    let cwd: String
    let reconciliationGeneration: Int
}

struct SessionContextSheet: View {
    let sessionID: String
    let initialHistoryEntryID: String?
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationActivityCoordinator) private var activityCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @State private var destination: ManageSessionDestination?
    @State private var showRename = false
    @State private var name = ""
    @State private var compacting = false
    @State private var exportedURL: URL?
    @State private var exportingFormat: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var workspacePresentation: SessionWorkspaceRowPresentation = .loading
    @State private var workspaceLoadGeneration = 0
    #if HOSTED_TEST
    @Environment(\.sessionWorkspaceRefreshProbe) private var workspaceProbe
    #endif
    @State private var capturedNoticeScope: InAppNoticeScope?
    @State private var fallbackNoticeScope = InAppNoticeScope.presentation(UUID())
    @State private var presentation: SessionContextPresentation?
    @State private var pendingModelSelection: SessionPendingModelSelection?
    @State private var pendingContextWindow: SessionPendingSetting<Int?>?
    @State private var pendingThinking: SessionPendingSetting<String>?
    @State private var sliderPresentation = ConfigurationSliderPresentation()
    @State private var settingContextWindow = false
    @State private var forkNavigation = ChatForkNavigationOwner()

    init(sessionID: String, initialHistoryEntryID: String? = nil, onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void) {
        self.sessionID = sessionID
        self.initialHistoryEntryID = initialHistoryEntryID
        self.onForkCreated = onForkCreated
    }

    private var presentationSource: SessionContextPresentation? {
        model.sessionContextPresentation(for: sessionID)
    }

    private var displayedPresentation: SessionContextPresentation? {
        guard let presentation else {
            return presentationActivity.allowsPresentationPublication ? presentationSource : nil
        }
        // Keep the installed semantic frame and control identity stable while
        // the authoritative revision advances for ordinary progress. Admission
        // callers read the latest revision directly from AppModel.
        return presentation
    }

    private var noticeScope: InAppNoticeScope {
        if let capturedNoticeScope { return capturedNoticeScope }
        if let target = model.presentationTarget(for: sessionID) {
            return .session(id: target.sessionID, generation: target.generation)
        }
        return fallbackNoticeScope
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let snapshot = displayedPresentation {
                        if model.connectionState == .connected,
                           let target = model.presentationTarget(for: sessionID),
                           !model.admitsLiveSessionCommands(target) {
                            TronPlaceholderState(
                                title: "Conversation needs to catch up",
                                detail: "Your conversation and draft are retained.",
                                icon: "arrow.triangle.2.circlepath",
                                actionTitle: "Retry Conversation"
                            ) {
                                Task { _ = await model.retryConversationSynchronization(target: target) }
                            }
                        }
                        SessionContextUsageCard(snapshot: snapshot)
                        modelSummaryCard(snapshot)
                        sessionSection(snapshot)
                        exportSection
                    } else {
                        TronLoadingState(label: "Loading session…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(18)
                .environment(\.tronSettingsSecondaryTextSizeAdjustment, SessionSummaryTypography.metadataSizeAdjustment)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { destination = .terminal } label: {
                        Image(systemName: "terminal")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .disabled(displayedPresentation == nil)
                    .accessibilityLabel("Terminal")
                    .accessibilityIdentifier("manage-session-terminal")
                    Button {
                        name = displayedPresentation?.name ?? ""
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .disabled(displayedPresentation == nil)
                    .accessibilityLabel("Rename Session")
                    .accessibilityIdentifier("manage-session-rename")
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Manage Session", accent: .tronEmerald)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let editor = sliderPresentation.session {
                            _ = sliderPresentation.beginClosing(editor)
                        } else { dismiss() }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
            #if HOSTED_TEST
            .onChange(of: workspacePresentation, initial: true) { _, value in
                workspaceProbe?.presentation = value
            }
            #endif
            .task(id: PresentationActivityTaskID(
                source: workspaceRefreshIdentity, presentationActive: workspaceSurfaceIsActive
            )) {
                guard let identity = workspaceRefreshIdentity else {
                    if workspaceSurfaceIsActive { workspacePresentation = .loading }
                    return
                }
                await monitorWorkspace(identity: identity)
            }
            .background {
                if presentationActivity.allowsPresentationPublication {
                    Color.clear
                        .onChange(of: presentationSource, initial: true) { _, value in
                            reconcilePresentation(value)
                        }
                }
            }
            .onChange(of: presentationActivity) { previous, current in
                guard !previous.allowsPresentationPublication,
                      current.allowsPresentationPublication else { return }
                reconcilePresentation(presentationSource)
            }
            .tronManagedSheet(
                item: $destination,
                identity: { "session.\(sessionID).manage.\($0.id)" },
                onDismiss: completeForkNavigationAfterHistoryDismissal
            ) { route in
                Group {
                    switch route {
                    case .agentInstructions:
                        AgentInstructionsSheet(sessionID: sessionID)
                    case .projectResources:
                        ProjectResourcesView(sessionID: sessionID)
                    case .history:
                        SessionTreeSheet(
                            sessionID: sessionID,
                            initialEntryID: initialHistoryEntryID,
                            onForkCreated: handleForkCreated,
                            onNavigated: handleNavigation
                        )
                    case .processHistory:
                        ProcessHistorySheet(sessionID: sessionID)
                    case .terminal:
                        TerminalSheet(sessionID: sessionID)
                    case .workspace:
                        WorkspaceInspectorSheet(sessionID: sessionID)
                    }
                }
                // Child sheets match Settings metadata sizing, not the compact
                // Manage Session summary's local adjustment.
                .environment(\.tronSettingsSecondaryTextSizeAdjustment, TronSettingsLayoutPolicy.metadataSizeAdjustment)
                // Only Session destinations inherit teal; the management
                // shell, usage, model, and export keep their own identities.
                .tronSettingsVisualTheme(accent: sessionRowAccent)
            }
            .tronTextEntryAlert(
                "Rename Session",
                isPresented: $showRename,
                text: $name,
                placeholder: "Name"
            ) { value in
                let trimmedName = value.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    do { try await model.renameSession(sessionID, name: trimmedName) }
                    catch { surfaceActionError(error) }
                }
            }
            .tronManagedSystemPresentation(
                isPresented: $showRename,
                identity: "manage-session.rename"
            )
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
        .tronConfigurationSliderHost(sliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignposts)
        .onAppear {
            if initialHistoryEntryID != nil, destination == nil {
                // Evidence routes enter the same managed history owner as a
                // user-opened session; they never issue an ad-hoc history RPC.
                destination = .history
            }
            if capturedNoticeScope == nil {
                capturedNoticeScope = model.presentationTarget(for: sessionID).map {
                    .session(id: $0.sessionID, generation: $0.generation)
                } ?? fallbackNoticeScope
            }
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            if let exportedURL {
                self.exportedURL = nil
                Task { await model.discardExportArtifact(exportedURL) }
            }
            model.noticeCenter.retire(scope: noticeScope)
        }
    }

    private func compactButton(_ snapshot: SessionContextPresentation) -> some View {
        let state = SessionCompactionControlPolicy.visualState(
            compactionQueued: snapshot.compactionQueued,
            submitting: compacting,
            phase: snapshot.phase
        )
        return Button {
            guard SessionCompactionControlPolicy.canRequest(
                phase: snapshot.phase,
                operationKind: snapshot.operationKind,
                compactionQueued: snapshot.compactionQueued,
                submitting: compacting,
                exporting: exportingFormat != nil
            ) else { return }
            compacting = true
            Task {
                defer { compacting = false }
                do { try await model.compact(sessionID: sessionID) }
                catch { surfaceActionError(error) }
            }
        } label: {
            TronInlineActionLabel(
                state == .queued ? "Queued" : state == .inProgress ? "Compacting" : "Compact Now",
                icon: state == .queued ? "clock" : "rectangle.compress.vertical",
                isWorking: state == .inProgress
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compact Now")
        .accessibilityIdentifier("manage-session-compact")
        .disabled(!SessionCompactionControlPolicy.canRequest(
            phase: snapshot.phase,
            operationKind: snapshot.operationKind,
            compactionQueued: snapshot.compactionQueued,
            submitting: compacting,
            exporting: exportingFormat != nil
        ))
        .accessibilityValue(snapshot.compactionQueued == true
            ? "Queued after current work"
            : (compacting || snapshot.phase == .compacting) ? "In progress" : "")
    }

    private var configurationRowAccent: Color { .tronPurple }
    private var sessionRowAccent: Color { .tronSessionTeal }
    private var exportRowAccent: Color { .tronSlate }

    private func processHistoryRow(_ snapshot: SessionContextPresentation) -> some View {
        let overview = snapshot.processOverview
        let durable = model.gatewayInfo?.capabilities.contains(SessionProcessAdmissionPolicy.historyCapability) == true
        let subtitle: String
        if let overview, overview.activeCount > 0 || overview.recentCount > 0 {
            let parts = [
                overview.activeCount > 0 ? "\(overview.activeCount) active" : nil,
                overview.recentCount > 0 ? "\(overview.recentCount) recent" : nil,
            ].compactMap { $0 }
            subtitle = parts.joined(separator: " · ")
        } else {
            subtitle = durable ? "Canonical history available" : "History unavailable"
        }
        return manageRow(
            icon: "clock.arrow.circlepath",
            title: "Subagent History",
            subtitle: subtitle,
            accent: sessionRowAccent
        ) { destination = .processHistory }
    }

    private func modelSelection(_ snapshot: SessionContextPresentation) -> Binding<ModelRef?> {
        Binding(
            get: {
                SessionModelSelectionPresentation.displayed(pending: pendingModelSelection, authoritative: snapshot.model)
            },
            set: { selection in
                guard let selection,
                      selection != SessionModelSelectionPresentation.displayed(
                        pending: pendingModelSelection, authoritative: snapshot.model
                      ),
                      let current = model.sessionContextPresentation(for: sessionID),
                      current.runtimeGeneration == snapshot.runtimeGeneration,
                      current.model == snapshot.model else { return }
                let pending = SessionPendingModelSelection(selection, snapshot: current)
                pendingModelSelection = pending
                pendingContextWindow = nil
                pendingThinking = nil
                Task {
                    do {
                        guard let admitted = model.sessionContextPresentation(for: sessionID),
                              pending.admitted(in: admitted) != nil else {
                            pendingModelSelection = pendingModelSelection?.rejecting(pending.id)
                            return
                        }
                        try await model.setModel(selection, sessionID: sessionID)
                        pendingModelSelection = pendingModelSelection?.confirming(pending.id)
                        if presentationActivity.allowsPresentationPublication { reconcilePresentation(presentationSource) }
                    } catch is CancellationError {
                        return
                    } catch {
                        pendingModelSelection = pendingModelSelection?.rejecting(pending.id)
                        surfaceActionError(error)
                    }
                }
            }
        )
    }

    private func modelSummaryCard(_ snapshot: SessionContextPresentation) -> some View {
        let thinkingScope = SessionThinkingEditScope(snapshot)
        let displayedThinking = pendingThinking?.admitted(in: snapshot)?.value ?? snapshot.thinkingLevel
        let selection = modelSelection(snapshot)
        let catalog = model.providerCatalog(for: .session(id: sessionID))?.models ?? []
        return SessionModelSummaryCard(
            selection: selection,
            catalog: catalog,
            automaticCompactionEnabled: snapshot.automaticCompactionEnabled
        ) {
            TronThinkingSelectionRow(
                selection: Binding(
                    get: { displayedThinking },
                    set: { level in
                        guard level != displayedThinking, pendingModelSelection == nil,
                              presentationActivity.allowsPresentationPublication,
                              let current = model.sessionContextPresentation(for: sessionID),
                              thinkingScope.admits(level, in: current),
                              (pendingThinking?.admitted(in: current)?.value ?? current.thinkingLevel) == displayedThinking else { return }
                        let pending = SessionPendingSetting(level, snapshot: snapshot)
                        pendingThinking = pending
                        Task {
                            do {
                                // The task may start after a runtime/model replacement.
                                guard let current = model.sessionContextPresentation(for: sessionID),
                                      thinkingScope.admits(level, in: current), pendingModelSelection == nil else {
                                    pendingThinking = pendingThinking?.rejecting(pending.id)
                                    return
                                }
                                try await model.setThinking(level, sessionID: sessionID)
                                pendingThinking = pendingThinking?.confirming(pending.id)
                                if presentationActivity.allowsPresentationPublication { reconcilePresentation(presentationSource) }
                            } catch {
                                pendingThinking = pendingThinking?.rejecting(pending.id)
                                surfaceActionError(error)
                            }
                        }
                    }
                ),
                levels: snapshot.availableThinkingLevels,
                accent: configurationRowAccent
            )
            .id(thinkingScope)
            .disabled(snapshot.phase.isActive || pendingModelSelection != nil)
            if model.gatewayInfo?.capabilities.contains("context-window.v1") == true,
               let policy = snapshot.contextWindowPolicy {
                let pendingWindow = pendingContextWindow?.admitted(in: snapshot)
                TronSettingsDivider(accent: configurationRowAccent)
                ContextWindowSelectionRow(
                    selection: Binding(
                        get: { pendingWindow.map(\.value) ?? policy.override },
                        set: { value in
                            // Bind the request to the model shown when the
                            // control was rendered. A late tap after a model
                            // switch must never mutate the replacement model.
                            guard !settingContextWindow, pendingModelSelection == nil,
                                  let current = model.sessionContextPresentation(for: sessionID),
                                  !current.phase.isActive,
                                  current.runtimeGeneration == snapshot.runtimeGeneration,
                                  current.contextWindowPolicy?.model == policy.model else { return }
                            let pending = SessionPendingSetting(value, snapshot: snapshot)
                            pendingContextWindow = pending
                            settingContextWindow = true
                            Task {
                                defer { settingContextWindow = false }
                                do {
                                    guard let admission = model.authoritativeSnapshot(for: sessionID),
                                          admission.runtimeGeneration == snapshot.runtimeGeneration,
                                          admission.contextWindowPolicy?.model == policy.model else { return }
                                    try await model.setContextWindow(value, for: policy.model, sessionID: sessionID, expectedRevision: admission.revision, expectedRuntimeGeneration: admission.runtimeGeneration)
                                    pendingContextWindow = pendingContextWindow?.confirming(pending.id)
                                    if presentationActivity.allowsPresentationPublication { reconcilePresentation(presentationSource) }
                                } catch {
                                    pendingContextWindow = pendingContextWindow?.rejecting(pending.id)
                                    surfaceActionError(error)
                                }
                            }
                        }
                    ),
                    limits: ContextWindowLimits(
                        minimum: policy.minimum,
                        maximum: policy.maximum,
                        default: policy.default,
                        longContextThreshold: nil
                    ),
                    inheritedValue: policy.default,
                    effectiveValue: pendingWindow.map { $0.value ?? policy.default } ?? policy.effective,
                    resetLabel: "Use configured default",
                    warning: policy.warning,
                    source: pendingWindow == nil ? policy.source : "pending",
                    accent: configurationRowAccent
                )
                .id("\(snapshot.runtimeGeneration):\(policy.model.contextWindowKey)")
                .disabled(snapshot.phase.isActive || settingContextWindow || pendingModelSelection != nil)
            }
        } compactAction: {
            compactButton(snapshot)
        }
    }

    private func reconcilePresentation(_ value: SessionContextPresentation?) {
        if presentation != value { presentation = value }
        pendingModelSelection = SessionModelSelectionPresentation.reconciledPending(
            pending: pendingModelSelection,
            authoritative: value?.model,
            runtimeGeneration: value?.runtimeGeneration
        )
        pendingContextWindow = pendingContextWindow?.reconciled(
            authoritative: value?.contextWindowPolicy?.override, snapshot: value
        )
        pendingThinking = pendingThinking?.reconciled(
            authoritative: value?.thinkingLevel ?? "", snapshot: value
        )
    }

    private func sessionSection(_ snapshot: SessionContextPresentation) -> some View {
        TronGlassCard(accent: sessionRowAccent) {
            VStack(spacing: 0) {
                gitRow
                divider()
                manageRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Agent Instructions",
                    subtitle: "Read the complete assembled instructions",
                    accent: sessionRowAccent
                ) { destination = .agentInstructions }
                divider()
                manageRow(
                    icon: "shippingbox",
                    title: "Project Resources",
                    subtitle: "Skills, prompts, commands, tools, and subagents",
                    accent: sessionRowAccent
                ) { destination = .projectResources }
                divider()
                manageRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Session History",
                    subtitle: "Review history, continue, or fork",
                    accent: sessionRowAccent
                ) { destination = .history }
                divider()
                processHistoryRow(snapshot)
                ForEach(Array(snapshot.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    divider()
                    TronSettingsRow(
                        icon: "exclamationmark.triangle",
                        title: diagnostic.message,
                        subtitle: diagnostic.type,
                        accent: sessionRowAccent
                    )
                }
            }
        }
    }

    private var exportSection: some View {
        TronGlassCard(accent: exportRowAccent) {
            VStack(spacing: 0) {
                exportRow(
                    format: "html",
                    icon: "doc.richtext",
                    subtitle: "Readable snapshot of committed session activity"
                )
                TronSettingsDivider(accent: exportRowAccent)
                exportRow(
                    format: "jsonl",
                    icon: "doc.text",
                    subtitle: "Complete canonical audit through the captured snapshot"
                )
                if let exportedURL {
                    TronSettingsDivider(accent: exportRowAccent)
                    ShareLink(item: exportedURL) {
                        TronSettingsRow(icon: "square.and.arrow.up", title: "Share \(exportedURL.lastPathComponent)", accent: exportRowAccent)
                    }
                }
            }
        }
    }

    private var gitRow: some View {
        Button { destination = .workspace } label: {
            SessionWorkspaceSummaryRow(presentation: workspacePresentation, accent: sessionRowAccent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current Branch and Workspace")
    }

    private func divider() -> some View {
        TronSettingsDivider(accent: sessionRowAccent)
    }

    private func manageRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func exportRow(
        format: String,
        icon: String,
        subtitle: String
    ) -> some View {
        Button { prepareExport(format) } label: {
            TronSettingsRow(
                icon: icon,
                title: SessionExportPresentationPolicy.title(for: format),
                subtitle: subtitle,
                accent: exportRowAccent
            ) {
                if SessionExportPresentationPolicy.showsProgress(
                    rowFormat: format,
                    activeFormat: exportingFormat
                ) {
                    TronPulseLoadingIndicator(size: 18)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!SessionExportPresentationPolicy.canStart(activeFormat: exportingFormat))
        .accessibilityIdentifier("session-export-\(format)")
        .accessibilityValue(SessionExportPresentationPolicy.showsProgress(
            rowFormat: format,
            activeFormat: exportingFormat
        ) ? "Exporting" : "")
    }

    private var workspaceSurfaceIsActive: Bool {
        presentationActivity.allowsPresentationPublication
            && (activityCoordinator?.activity(for: surfaceToken).allowsPresentationPublication ?? true)
    }

    private var workspaceRefreshIdentity: SessionWorkspaceRefreshIdentity? {
        guard workspaceSurfaceIsActive,
              model.connectionState == .connected, !model.isReconcilingForeground,
              let profileID = model.selectedGatewayProfileID(),
              let target = model.presentationTarget(for: sessionID),
              model.hasMountedSessionAuthority(target),
              let snapshot = model.sessionContextPresentation(for: sessionID) else { return nil }
        return SessionWorkspaceRefreshIdentity(
            profileID: profileID, target: target, runtimeGeneration: snapshot.runtimeGeneration,
            cwd: snapshot.cwd, reconciliationGeneration: model.foregroundReconciliationGeneration
        )
    }

    private func monitorWorkspace(identity: SessionWorkspaceRefreshIdentity) async {
        workspaceLoadGeneration &+= 1
        let generation = workspaceLoadGeneration
        guard workspaceRefreshIdentity == identity, !Task.isCancelled else { return }
        workspacePresentation = .loading
        // Scene activation can precede transport/subscription reconciliation.
        // The task keys off admitted authority, so readiness restarts this read
        // immediately instead of leaving a transient error until another wake.
        while !Task.isCancelled, workspaceRefreshIdentity == identity {
            do {
                let inspection = try await model.workspaceInspection.inspect(sessionID: sessionID)
                guard generation == workspaceLoadGeneration, !Task.isCancelled,
                      workspaceRefreshIdentity == identity else { return }
                workspacePresentation = SessionWorkspaceRowPresentation.resolve(inspection)
            } catch is CancellationError {
                return
            } catch {
                guard generation == workspaceLoadGeneration, !Task.isCancelled,
                      workspaceRefreshIdentity == identity else { return }
                workspacePresentation = .failed(error.localizedDescription)
            }
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
        }
    }

    private func handleForkCreated(_ route: AppModel.SessionNavigationRoute) {
        forkNavigation.stage(route)
        destination = nil
    }

    private func completeForkNavigationAfterHistoryDismissal() {
        guard let route = forkNavigation.consume() else { return }
        onForkCreated(route)
    }

    private func handleNavigation() {
        dismiss()
    }

    private func surfaceActionError(_ error: Error) {
        guard !(error is CancellationError) else { return }
        model.presentError(error, scope: noticeScope)
    }

    private func prepareExport(_ format: String) {
        guard SessionExportPresentationPolicy.canStart(activeFormat: exportingFormat) else { return }
        exportingFormat = format
        exportTask = Task {
            defer {
                exportingFormat = nil
                exportTask = nil
            }
            do {
                let artifact = try await model.exportSession(sessionID: sessionID, format: format)
                guard !Task.isCancelled else {
                    await model.discardExportArtifact(artifact)
                    return
                }
                if let previous = exportedURL { await model.discardExportArtifact(previous) }
                guard !Task.isCancelled else {
                    await model.discardExportArtifact(artifact)
                    return
                }
                exportedURL = artifact
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                model.presentError(error, scope: noticeScope)
            }
        }
    }
}

#if HOSTED_TEST
@MainActor @Observable
final class SessionWorkspaceRefreshProbe {
    var presentation: SessionWorkspaceRowPresentation = .loading
}

extension EnvironmentValues {
    @Entry var sessionWorkspaceRefreshProbe: SessionWorkspaceRefreshProbe? = nil
}
#endif
