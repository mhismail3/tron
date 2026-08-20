import SwiftUI

private enum ManageSessionDestination: String, Identifiable {
    case agentContext, projectResources, history, terminal
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

    static func canRequest(snapshot: SessionSnapshot, submitting: Bool, exporting: Bool) -> Bool {
        canRequest(
            phase: snapshot.phase,
            operationKind: snapshot.operation?.kind,
            compactionQueued: snapshot.compactionQueued == true,
            submitting: submitting,
            exporting: exporting
        )
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
            return "Context usage: unavailable until fresh usage is reported"
        }
    }
}

enum SessionGitLoadAdmission {
    static func admits(
        requestGeneration: Int,
        currentGeneration: Int,
        requestedCwd: String,
        currentCwd: String?
    ) -> Bool {
        requestGeneration == currentGeneration && requestedCwd == currentCwd
    }
}

enum SessionGitPresentation: Equatable {
    case loading
    case notRepository
    case loaded(branch: String, dirty: Bool)
    case failed(String)

    static func resolve(_ inspection: GitInspection) -> SessionGitPresentation {
        guard inspection.isRepository,
              let branch = inspection.branch,
              !branch.isEmpty else { return .notRepository }
        return .loaded(branch: branch, dirty: inspection.isDirty)
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
    @State private var destination: ManageSessionDestination?
    @State private var showRename = false
    @State private var name = ""
    @State private var compacting = false
    @State private var exportedURL: URL?
    @State private var exportingFormat: String?
    @State private var exportError: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var gitPresentation: SessionGitPresentation = .loading
    @State private var gitLoadGeneration = 0
    @State private var extensionActivityGroupID: String?
    @State private var extensionActivityRoute: ExtensionActivityRoute?
    @State private var showExtensionActivity = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let snapshot = model.authoritativeSnapshot(for: sessionID) {
                        contextUsageCard(snapshot)
                        configurationSection(snapshot)
                        extensionActivitySection(snapshot)
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
                    if let snapshot = model.authoritativeSnapshot(for: sessionID) {
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
            .task(id: model.authoritativeSnapshot(for: sessionID)?.cwd) {
                gitLoadGeneration &+= 1
                let generation = gitLoadGeneration
                gitPresentation = .loading
                await loadGit(
                    snapshot: model.authoritativeSnapshot(for: sessionID),
                    generation: generation
                )
            }
            .sheet(isPresented: $showExtensionActivity) {
                ExtensionDetailsSheet(sessionID: sessionID, groupID: extensionActivityGroupID)
            }
            .sheet(item: $extensionActivityRoute) { route in
                ExtensionRunDetailsSheet(sessionID: sessionID, activityID: route.id)
            }
            .sheet(item: $destination) { route in
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
                case .terminal:
                    TerminalSheet(sessionID: sessionID)
                }
            }
            .alert("Rename Session", isPresented: $showRename) {
                TextField("Name", text: $name)
                Button("Save") {
                    Task {
                        do { try await model.renameSession(sessionID, name: name) }
                        catch { surfaceActionError(error) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "The session could not be exported.")
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            if let exportedURL {
                self.exportedURL = nil
                Task { await model.discardExportArtifact(exportedURL) }
            }
        }
    }

    private func compactToolbarButton(_ snapshot: SessionSnapshot) -> some View {
        Button {
            guard SessionCompactionControlPolicy.canRequest(
                snapshot: snapshot,
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
                    ProgressView().controlSize(.small)
                case .idle:
                    EmptyView()
                }
                Text("Compact")
            }
            .tronToolbarAction()
        }
        .disabled(!SessionCompactionControlPolicy.canRequest(
            snapshot: snapshot,
            submitting: compacting,
            exporting: exportingFormat != nil
        ))
        .accessibilityValue(snapshot.compactionQueued == true
            ? "Queued after current work"
            : (compacting || snapshot.phase == .compacting) ? "In progress" : "")
    }

    private func contextUsageCard(_ snapshot: SessionSnapshot) -> some View {
        let usage = SessionContextUsagePresentation(snapshot.contextUsage)
        let cacheValue = snapshot.stats.latestCacheHitRate.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))%"
        } ?? "—"
        let contextValue: String = switch usage {
        case .available(let used, let window, _):
            "\(used.formatted(.number.notation(.compactName)))/\(window.formatted(.number.notation(.compactName)))"
        case .unavailable:
            "—"
        }
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
                        .font(TronTypography.code(size: TronTypography.sizeXL, weight: .bold))
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
                Text("Context usage unavailable")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text("A fresh assistant response will provide the current token-window estimate.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func contextAndCompactionRow(contextValue: String, snapshot: SessionSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(contextValue)
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
                .accessibilityLabel("Context usage: \(contextValue)")

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

    @ViewBuilder
    private func extensionActivitySection(_ snapshot: SessionSnapshot) -> some View {
        let groups = ChatExtensionWidgetPolicy.groups(
            snapshot.extensionPresentation,
            executions: snapshot.toolExecutions,
            activities: snapshot.extensionActivities ?? []
        ).compactMap { group -> ExtensionWidgetGroup? in
            let activities = group.activities.filter { !$0.isLive }
            let services = group.services.filter { $0.status != "Running" }
            guard !activities.isEmpty || !services.isEmpty else { return nil }
            return ExtensionWidgetGroup(
                id: group.id,
                label: group.label,
                items: [],
                statuses: [],
                services: services,
                activities: activities
            )
        }
        if !groups.isEmpty {
            TronSettingsGroup("Extension History", detail: "Completed extension work retained for this runtime.", accent: .tronEmerald) {
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        Button {
                            if group.activities.count == 1, let activity = group.activities.first {
                                extensionActivityRoute = ExtensionActivityRoute(id: activity.id)
                            } else {
                                extensionActivityGroupID = group.id
                                showExtensionActivity = true
                            }
                        } label: {
                            TronSettingsRow(
                                icon: group.hasLiveContent ? "circle.dotted" : "clock.arrow.circlepath",
                                title: group.label,
                                subtitle: extensionActivitySubtitle(group),
                                subtitleRole: .dynamicValue,
                                accent: .tronEmerald
                            ) {
                                Image(systemName: "chevron.right")
                                    .font(TronTypography.caption)
                                    .foregroundStyle(Color.tronTextMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Extension activity: \(group.label)")
                        if group.id != groups.last?.id { TronSettingsDivider(accent: .tronEmerald) }
                    }
                }
            }
        }
    }

    private func extensionActivitySubtitle(_ group: ExtensionWidgetGroup) -> String {
        let parts = [
            group.activities.count > 0 ? "\(group.activities.count) completed runs" : nil,
            group.services.count > 0 ? "\(group.services.count) tools" : nil,
            group.items.count > 0 ? "\(group.items.count) widgets" : nil,
            group.statuses.count > 0 ? "\(group.statuses.count) statuses" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "View extension details" : parts.joined(separator: " · ")
    }

    private func configurationSection(_ snapshot: SessionSnapshot) -> some View {
        TronSettingsGroup("Configuration", accent: .tronPurple) {
            VStack(spacing: 0) {
                Menu {
                    ForEach(
                        model.providerCatalog(for: .session(id: sessionID))?.models.filter(\.available) ?? [],
                        id: \.ref
                    ) { candidate in
                        Button {
                            Task {
                                do { try await model.setModel(candidate.ref, sessionID: sessionID) }
                                catch { surfaceActionError(error) }
                            }
                        } label: {
                            if snapshot.model == candidate.ref { Label(candidate.displayName, systemImage: "checkmark") }
                            else { Text(candidate.displayName) }
                        }
                    }
                } label: {
                    TronValueRow(
                        icon: "cpu",
                        title: "Model",
                        value: snapshot.model?.displayDescription ?? "Not selected",
                        accent: configurationRowAccent
                    )
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Model: \(snapshot.model?.displayDescription ?? "Not selected")")
                TronSettingsDivider(accent: .tronPurple)
                Menu {
                    ForEach(snapshot.availableThinkingLevels, id: \.self) { level in
                        Button {
                            Task {
                                do { try await model.setThinking(level, sessionID: sessionID) }
                                catch { surfaceActionError(error) }
                            }
                        } label: {
                            if snapshot.thinkingLevel == level { Label(level.capitalized, systemImage: "checkmark") }
                            else { Text(level.capitalized) }
                        }
                    }
                } label: {
                    TronValueRow(
                        icon: "brain",
                        title: "Thinking",
                        detail: "Reasoning effort for this session",
                        value: snapshot.thinkingLevel.capitalized,
                        accent: configurationRowAccent
                    )
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Thinking: \(snapshot.thinkingLevel.capitalized)")
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

    private func sessionSection(_ snapshot: SessionSnapshot) -> some View {
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
                    subtitle: "Readable session archive"
                )
                divider()
                exportRow(
                    format: "jsonl",
                    icon: "doc.text",
                    subtitle: "Complete canonical audit"
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
        Group {
            switch gitPresentation {
            case .loading:
                TronSettingsRow(
                    icon: "arrow.triangle.branch",
                    title: "Current Branch",
                    subtitle: "Checking workspace…",
                    subtitleRole: .dynamicValue,
                    accent: sessionRowAccent
                ) {
                    ProgressView().controlSize(.small)
                }
            case .notRepository:
                TronSettingsRow(icon: "folder", title: "Current Branch", subtitle: "Workspace is not a Git repository", accent: sessionRowAccent) {
                    Text("None").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                }
            case .loaded(let branch, let dirty):
                TronSettingsRow(
                    icon: "arrow.triangle.branch",
                    title: "Current Branch",
                    subtitle: dirty ? "Uncommitted changes" : "Working tree clean",
                    subtitleRole: .dynamicValue,
                    accent: sessionRowAccent
                ) {
                    Text(branch)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                }
            case .failed:
                TronSettingsRow(
                    icon: "exclamationmark.triangle",
                    title: "Current Branch",
                    subtitle: "Unable to inspect this workspace",
                    subtitleRole: .dynamicValue,
                    accent: sessionRowAccent
                ) {
                    Text("Unavailable").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                }
            }
        }
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
                    ProgressView().controlSize(.small)
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

    private func loadGit(snapshot: SessionSnapshot?, generation: Int) async {
        guard let snapshot else { return }
        do {
            let inspection = try await model.gatewayDiagnostics.inspectGit(path: snapshot.cwd)
            guard SessionGitLoadAdmission.admits(
                requestGeneration: generation,
                currentGeneration: gitLoadGeneration,
                requestedCwd: snapshot.cwd,
                currentCwd: model.authoritativeSnapshot(for: sessionID)?.cwd
            ) else { return }
            gitPresentation = SessionGitPresentation.resolve(inspection)
        } catch is CancellationError {
            return
        } catch {
            guard SessionGitLoadAdmission.admits(
                requestGeneration: generation,
                currentGeneration: gitLoadGeneration,
                requestedCwd: snapshot.cwd,
                currentCwd: model.authoritativeSnapshot(for: sessionID)?.cwd
            ) else { return }
            gitPresentation = .failed(error.localizedDescription)
            surfaceActionError(error)
        }
    }

    private func handleForkCreated(_ route: AppModel.SessionNavigationRoute) {
        dismiss()
        onForkCreated(route)
    }

    private func handleNavigation() {
        dismiss()
    }

    private func surfaceActionError(_ error: Error) {
        guard !(error is CancellationError) else { return }
        model.lastError = error.localizedDescription
    }

    private func prepareExport(_ format: String) {
        guard SessionExportPresentationPolicy.canStart(activeFormat: exportingFormat) else { return }
        exportingFormat = format
        exportError = nil
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
                exportError = error.localizedDescription
            }
        }
    }
}

private struct AgentContextSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showInstructions = false

    private var summary: AgentContextSummary { AgentContextSummary(context: model.context) }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Label("This is the context currently assembled for the agent. Project resource inventories and schemas are kept in Project Resources.", systemImage: "info.circle")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: .tronPurple, tintOpacity: 0.08)

                    VStack(alignment: .leading, spacing: 10) {
                        TronSettingsGroup("Instructions", detail: "Assembled runtime guidance", accent: .tronPurple) {
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

                    TronSettingsGroup("Current Context", accent: .tronCyan) {
                        VStack(spacing: 0) {
                            contextMetricRow(
                                icon: "gauge.with.dots.needle.50percent",
                                title: "Context Window",
                                value: contextWindowLabel
                            )
                            TronSettingsDivider(accent: .tronCyan)
                            contextMetricRow(icon: "bubble.left.and.bubble.right", title: "Session Messages", value: countLabel(summary.messageCount))
                            TronSettingsDivider(accent: .tronCyan)
                            contextMetricRow(icon: "wrench.and.screwdriver", title: "Tool Calls", value: countLabel(summary.toolCallCount))
                        }
                    }

                    TronSettingsGroup("Capabilities", detail: "Detailed inventory lives in Project Resources", accent: .tronTeal) {
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
            .task(id: model.sessionContextRevision(for: sessionID)) {
                await model.loadContext(sessionID: sessionID)
            }
            .sheet(isPresented: $showInstructions) {
                NavigationStack {
                    ScrollView {
                        Text(summary.instructions)
                            .font(TronTypography.body)
                            .foregroundStyle(Color.tronTextPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tronScrollEdgeChrome()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) { TronSheetTitle(title: "Instructions", accent: .tronPurple) }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showInstructions = false }.tronToolbarAction()
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

    private var contextWindowLabel: String {
        guard let tokens = summary.contextTokens, let window = summary.contextWindow else { return "Unavailable" }
        return "\(tokens.formatted(.number.notation(.compactName))) of \(window.formatted(.number.notation(.compactName)))"
    }

    private func countLabel(_ count: Int?) -> String { count?.formatted() ?? "Unavailable" }

    private func contextMetricRow(icon: String, title: String, value: String) -> some View {
        TronValueRow(icon: icon, title: title, value: value, accent: .tronCyan)
    }
}
