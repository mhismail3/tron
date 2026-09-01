import SwiftUI

private enum ManageSessionDestination: String, Identifiable {
    case agentContext, projectResources, history, processHistory, terminal, workspace
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
        format == "jsonl" ? "JSONL Export" : "HTML Export"
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

struct AgentContextSummary: Equatable {
    static let maximumInstructionPreviewCharacters = 900

    let instructions: String
    let instructionPreview: String
    let activeToolCount: Int
    let availableToolCount: Int
    let commandCount: Int
    let messageCount: Int?
    let toolCallCount: Int?
    let contextTokens: Int?
    let contextWindow: Int?

    init(context: JSONValue?) {
        let root = context?.objectValue ?? [:]
        instructions = root["systemPrompt"]?.stringValue ?? "Instructions are unavailable."
        if instructions.count > Self.maximumInstructionPreviewCharacters {
            instructionPreview = String(instructions.prefix(Self.maximumInstructionPreviewCharacters)) + "…"
        } else {
            instructionPreview = instructions
        }
        activeToolCount = root["activeTools"]?.arrayValue?.count ?? 0
        availableToolCount = root["availableTools"]?.arrayValue?.count
            ?? root["tools"]?.arrayValue?.count
            ?? 0
        commandCount = root["commands"]?.arrayValue?.count ?? 0
        let stats = root["stats"]?.objectValue
        messageCount = stats?["totalMessages"]?.intValue
        toolCallCount = stats?["toolCalls"]?.intValue
        let usage = root["contextUsage"]?.objectValue
        contextTokens = usage?["tokens"]?.intValue
        contextWindow = usage?["contextWindow"]?.intValue
    }
}

struct SessionContextSheet: View {
    let sessionID: String
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var destination: ManageSessionDestination?
    @State private var showRename = false
    @State private var name = ""
    @State private var compacting = false
    @State private var exportedURL: URL?
    @State private var exportingFormat: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var workspacePresentation: SessionWorkspaceRowPresentation = .loading
    @State private var workspaceLoadGeneration = 0
    @State private var capturedNoticeScope: InAppNoticeScope?
    @State private var fallbackNoticeScope = InAppNoticeScope.presentation(UUID())
    @State private var presentation: SessionContextPresentation?
    @State private var forkNavigation = ChatForkNavigationOwner()

    private var presentationSource: SessionContextPresentation? {
        model.sessionContextPresentation(for: sessionID)
    }

    private var displayedPresentation: SessionContextPresentation? {
        presentation ?? (
            presentationActivity.allowsPresentationPublication ? presentationSource : nil
        )
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
                        contextUsageCard(snapshot)
                        configurationSection(snapshot)
                        processHistorySection(snapshot)
                        sessionSection(snapshot)
                    } else {
                        TronLoadingState(label: "Loading session…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let snapshot = displayedPresentation {
                        compactToolbarButton(snapshot)
                    }
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Manage Session", accent: .tronEmerald)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task(id: "\(sessionID):\(presentation?.cwd ?? "none"):\(presentationActivity.allowsPresentationPublication)") {
                guard presentationActivity.allowsPresentationPublication else { return }
                await monitorWorkspace(snapshot: presentation)
            }
            .background {
                if presentationActivity.allowsPresentationPublication {
                    Color.clear
                        .onChange(of: presentationSource, initial: true) { _, value in
                            if presentation != value { presentation = value }
                        }
                }
            }
            .onChange(of: presentationActivity) { previous, current in
                guard !previous.allowsPresentationPublication,
                      current.allowsPresentationPublication else { return }
                let value = presentationSource
                if presentation != value { presentation = value }
            }
            .tronManagedSheet(
                item: $destination,
                identity: { "session.\(sessionID).manage.\($0.id)" },
                onDismiss: completeForkNavigationAfterHistoryDismissal
            ) { route in
                switch route {
                case .agentContext:
                    AgentContextSheet(sessionID: sessionID)
                case .projectResources:
                    ProjectResourcesView(sessionID: sessionID)
                case .history:
                    SessionTreeSheet(
                        sessionID: sessionID,
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
        .onAppear {
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

    private func compactToolbarButton(_ snapshot: SessionContextPresentation) -> some View {
        Button {
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
            HStack(spacing: 6) {
                switch SessionCompactionControlPolicy.visualState(
                    compactionQueued: snapshot.compactionQueued == true,
                    submitting: compacting,
                    phase: snapshot.phase
                ) {
                case .queued:
                    Image(systemName: "clock")
                case .inProgress:
                    TronPulseLoadingIndicator(size: 18)
                case .idle:
                    Image(systemName: "rectangle.compress.vertical")
                }
                Text("Compact")
            }
            .tronToolbarAction()
        }
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

    private func contextUsageCard(_ snapshot: SessionContextPresentation) -> some View {
        let usage = SessionContextUsagePresentation(snapshot.contextUsage)
        let cacheValue = snapshot.stats.latestCacheHitRate.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))%"
        } ?? "—"
        let contextValue: String? = switch usage {
        case .available(let used, let window, _):
            "\(used.formatted(.number.notation(.compactName)))/\(window.formatted(.number.notation(.compactName)))"
        case .unavailable:
            nil
        }
        let refreshPresentation = SessionContextUsageRefreshPresentation(
            lastTranscriptKind: snapshot.lastTranscriptKind,
            assistantMessages: snapshot.stats.assistantMessages
        )
        let statistics = [
            (cacheValue, "Cache Hit"),
            ("\(snapshot.stats.tokens.cacheRead.formatted(.number.notation(.compactName))) / \(snapshot.stats.tokens.cacheWrite.formatted(.number.notation(.compactName)))", "Read / Write"),
            (snapshot.stats.tokens.input.formatted(.number.notation(.compactName)), "Input"),
            (snapshot.stats.tokens.output.formatted(.number.notation(.compactName)), "Output"),
            (snapshot.stats.cost.formatted(.currency(code: "USD")), "Cost"),
        ]

        return VStack(alignment: .leading, spacing: 9) {
            switch usage {
            case .available(let used, let contextWindow, let percent):
                let remaining = max(0, contextWindow - used)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(remaining.formatted(.number.notation(.compactName))) tokens left")
                        .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(Int(percent.rounded()))% used")
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                ProgressView(value: percent, total: 100)
                    .tint(Color.tronEmerald)
                    .accessibilityLabel("Context used")
                    .accessibilityValue("\(Int(percent.rounded())) percent")
            case .unavailable:
                Text("0% used")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(refreshPresentation.detail)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: 0, total: 100)
                    .tint(Color.tronEmerald)
                    .accessibilityLabel("Context estimate pending")
                    .accessibilityValue("Displayed as zero percent until refreshed")
            }

            contextAndCompactionRow(contextValue: contextValue, snapshot: snapshot)

            Divider().overlay(Color.tronEmerald.opacity(0.14))

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 6) {
                    ForEach(0..<statistics.count, id: \.self) { index in
                        metric(statistics[index].0, statistics[index].1)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<statistics.count, id: \.self) { index in
                        metric(statistics[index].0, statistics[index].1)
                    }
                }
            }
        }
        .padding(14)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usage.accessibilityLabel)
    }

    private func contextAndCompactionRow(contextValue: String?, snapshot: SessionContextPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let contextValue {
                Text(contextValue)
                    .font(TronTypography.secondaryCodeDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                    .accessibilityLabel("Context usage: \(contextValue)")
            }

            Spacer(minLength: 8)

            Label(
                "Automatic Compaction: \(SessionCompactionControlPolicy.automaticStatus(snapshot.automaticCompactionEnabled))",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(TronTypography.secondaryCodeDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .truncationMode(.tail)
            .multilineTextAlignment(.trailing)
            .layoutPriority(0)
            .accessibilityLabel("Automatic compaction: \(SessionCompactionControlPolicy.automaticStatus(snapshot.automaticCompactionEnabled))")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(TronTypography.code(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private var configurationRowAccent: Color { .tronPurple }
    private var sessionRowAccent: Color { .tronBlue }

    private func processHistorySection(_ snapshot: SessionContextPresentation) -> some View {
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
        return TronSettingsGroup(
            "Subagent History",
            detail: "Delegated sessions for this conversation.",
            accent: .tronEmerald
        ) {
            manageRow(
                icon: "clock.arrow.circlepath",
                title: "Subagent History",
                subtitle: subtitle,
                accent: .tronEmerald
            ) { destination = .processHistory }
        }
    }

    private func configurationSection(_ snapshot: SessionContextPresentation) -> some View {
        TronSettingsGroup("Configuration", accent: .tronPurple) {
            VStack(spacing: 0) {
                TronModelSelectionRow(
                    selection: Binding(
                        get: { snapshot.model },
                        set: { selection in
                            guard let selection, selection != snapshot.model else { return }
                            Task {
                                do { try await model.setModel(selection, sessionID: sessionID) }
                                catch { surfaceActionError(error) }
                            }
                        }
                    ),
                    models: model.providerCatalog(for: .session(id: sessionID))?.models.filter(\.available) ?? [],
                    navigationTitle: "Session Model",
                    accent: configurationRowAccent
                )
                TronSettingsDivider(accent: .tronPurple)
                TronThinkingSelectionRow(
                    selection: Binding(
                        get: { snapshot.thinkingLevel },
                        set: { level in
                            guard level != snapshot.thinkingLevel else { return }
                            Task {
                                do { try await model.setThinking(level, sessionID: sessionID) }
                                catch { surfaceActionError(error) }
                            }
                        }
                    ),
                    levels: snapshot.availableThinkingLevels,
                    accent: configurationRowAccent
                )
                TronSettingsDivider(accent: .tronPurple)
                manageRow(
                    icon: "shippingbox",
                    title: "Project Resources",
                    subtitle: "Extensions, prompts, skills, context files, and tools",
                    accent: configurationRowAccent
                ) { destination = .projectResources }
                TronSettingsDivider(accent: .tronPurple)
                manageRow(icon: "pencil", title: "Rename Session", accent: configurationRowAccent) {
                    name = snapshot.name ?? ""
                    showRename = true
                }
            }
        }
    }

    private func sessionSection(_ snapshot: SessionContextPresentation) -> some View {
        TronSettingsGroup("Session", detail: snapshot.cwd, detailInline: true, accent: .tronCyan) {
            VStack(spacing: 0) {
                manageRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Agent Context",
                    subtitle: "Instructions, current context, and active capabilities",
                    accent: sessionRowAccent
                ) { destination = .agentContext }
                divider()
                manageRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Session History",
                    subtitle: "Review recent history, audit changes, continue, or create a fork",
                    accent: sessionRowAccent
                ) { destination = .history }
                divider()
                manageRow(
                    icon: "terminal",
                    title: "Terminal",
                    subtitle: "Open or reattach the retained Mac terminal",
                    accent: sessionRowAccent
                ) { destination = .terminal }
                divider()
                gitRow
                divider()
                exportRow(
                    format: "html",
                    icon: "doc.richtext",
                    subtitle: "Readable snapshot of committed session activity"
                )
                divider()
                exportRow(
                    format: "jsonl",
                    icon: "doc.text",
                    subtitle: "Complete canonical audit through the captured snapshot"
                )
                if let exportedURL {
                    divider()
                    ShareLink(item: exportedURL) {
                        TronSettingsRow(icon: "square.and.arrow.up", title: "Share \(exportedURL.lastPathComponent)", accent: sessionRowAccent)
                    }
                }
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

    private var gitRow: some View {
        Button { destination = .workspace } label: {
            Group {
                switch workspacePresentation {
                case .loading:
                    TronSettingsRow(
                        icon: "arrow.triangle.branch",
                        title: "Current Branch",
                        subtitle: "Checking workspace…",
                        subtitleRole: .dynamicValue,
                        accent: sessionRowAccent
                    ) {
                        TronPulseLoadingIndicator(size: 18)
                    }
                case .notRepository:
                    TronSettingsRow(icon: "folder", title: "Current Branch", subtitle: "Browse workspace files", accent: sessionRowAccent) {
                        Text("No Git").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                    }
                case .loaded(let branch, let dirty, let changeCount):
                    let workingTreeStatus = dirty
                        ? "\(changeCount) uncommitted \(changeCount == 1 ? "change" : "changes")"
                        : "Working tree clean"
                    TronSettingsRow(
                        icon: "arrow.triangle.branch",
                        title: "Current Branch",
                        subtitle: branch,
                        subtitleRole: .dynamicValue,
                        subtitleLineLimit: 1,
                        accent: sessionRowAccent
                    ) {
                        Text(workingTreeStatus)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(1)
                    }
                case .failed:
                    TronSettingsRow(
                        icon: "exclamationmark.triangle",
                        title: "Current Branch",
                        subtitle: "Tap to retry workspace inspection",
                        subtitleRole: .dynamicValue,
                        accent: sessionRowAccent
                    ) {
                        Text("Unavailable").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current Branch and Workspace")
    }

    private func divider() -> some View {
        TronSettingsDivider(accent: .tronCyan)
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
                accent: sessionRowAccent
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

    private func monitorWorkspace(snapshot: SessionContextPresentation?) async {
        guard let snapshot else { return }
        workspaceLoadGeneration &+= 1
        let generation = workspaceLoadGeneration
        workspacePresentation = .loading
        while !Task.isCancelled,
              presentationActivity.allowsPresentationPublication,
              presentation?.cwd == snapshot.cwd {
            do {
                let inspection = try await model.workspaceInspection.inspect(sessionID: sessionID)
                guard generation == workspaceLoadGeneration,
                      presentation?.cwd == snapshot.cwd,
                      !Task.isCancelled else { return }
                workspacePresentation = SessionWorkspaceRowPresentation.resolve(inspection)
            } catch is CancellationError {
                return
            } catch {
                guard generation == workspaceLoadGeneration,
                      presentation?.cwd == snapshot.cwd else { return }
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

private struct AgentContextSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var showInstructions = false

    var body: some View {
        let summary = AgentContextSummary(context: model.context)
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Label("This is the context currently assembled for the agent. Project resource inventories and schemas are kept in Project Resources.", systemImage: "info.circle")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronScrollSurface(accent: .tronPurple, tintOpacity: 0.08)

                    VStack(alignment: .leading, spacing: 10) {
                        TronSettingsGroup(
                            "Instructions",
                            detail: "Assembled runtime guidance",
                            accent: .tronPurple,
                            surfaceStyle: .scrollOptimized
                        ) {
                            Text(summary.instructionPreview)
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { showInstructions = true } label: {
                            TronSettingsRow(
                                icon: "doc.plaintext",
                                title: "Read Full Instructions",
                                subtitle: "Open the complete assembled guidance",
                                accent: .tronPurple
                            )
                        }
                        .buttonStyle(.plain)
                        .tronGlassSurface(accent: .tronPurple, tintOpacity: 0.10, interactive: true)
                        .accessibilityIdentifier("agent-context-full-instructions")
                    }

                    TronSettingsGroup("Current Context", accent: .tronCyan, surfaceStyle: .scrollOptimized) {
                        VStack(spacing: 0) {
                            contextMetricRow(
                                icon: "gauge.with.dots.needle.50percent",
                                title: "Context Window",
                                value: contextWindowLabel(summary)
                            )
                            TronSettingsDivider(accent: .tronCyan)
                            contextMetricRow(icon: "bubble.left.and.bubble.right", title: "Session Messages", value: countLabel(summary.messageCount))
                            TronSettingsDivider(accent: .tronCyan)
                            contextMetricRow(icon: "wrench.and.screwdriver", title: "Tool Calls", value: countLabel(summary.toolCallCount))
                        }
                    }

                    TronSettingsGroup(
                        "Capabilities",
                        detail: "Detailed inventory lives in Project Resources",
                        accent: .tronTeal,
                        surfaceStyle: .scrollOptimized
                    ) {
                        VStack(spacing: 0) {
                            contextMetricRow(
                                icon: "wrench.and.screwdriver",
                                title: "Tool Access",
                                value: "\(summary.activeToolCount) of \(summary.availableToolCount) active"
                            )
                            TronSettingsDivider(accent: .tronTeal)
                            contextMetricRow(icon: "command", title: "Available Commands", value: summary.commandCount.formatted())
                            TronSettingsDivider(accent: .tronTeal)
                            TronSettingsRow(
                                icon: "shippingbox",
                                title: "Project Resources",
                                subtitle: "Return to Manage Session to inspect extensions, prompts, skills, files, tools, and schemas",
                                accent: .tronTeal
                            )
                        }
                    }

                    TronTechnicalJSONRow(
                        value: model.context ?? .null,
                        sheetTitle: "Agent Context JSON"
                    )
                }
                .padding(18)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Agent Context", accent: .tronPurple) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task(id: "\(model.sessionContextRevision(for: sessionID)):\(presentationActivity.allowsPresentationPublication)") {
                guard presentationActivity.allowsPresentationPublication else { return }
                await model.loadContext(sessionID: sessionID)
            }
            .tronManagedSheet(
                isPresented: $showInstructions,
                identity: "session.\(sessionID).agent-context.instructions"
            ) {
                NavigationStack {
                    TronReadOnlyTextView(text: summary.instructions)
                        .tronTopBlurSurface()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) { TronSheetTitle(title: "Instructions", accent: .tronPurple) }
                            ToolbarItem(placement: .confirmationAction) {
                                Button { showInstructions = false } label: {
                                    TronToolbarTextLabel("Done", systemImage: "checkmark")
                                }
                                .tronToolbarAction()
                            }
                        }
                }
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
    }

    private func contextWindowLabel(_ summary: AgentContextSummary) -> String {
        guard let tokens = summary.contextTokens, let window = summary.contextWindow else { return "Unavailable" }
        return "\(tokens.formatted(.number.notation(.compactName))) of \(window.formatted(.number.notation(.compactName)))"
    }

    private func countLabel(_ count: Int?) -> String { count?.formatted() ?? "Unavailable" }

    private func contextMetricRow(icon: String, title: String, value: String) -> some View {
        TronValueRow(icon: icon, title: title, value: value, accent: .tronCyan)
    }
}
