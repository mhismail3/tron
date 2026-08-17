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
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var gitPresentation: SessionGitPresentation = .loading
    @State private var gitLoadGeneration = 0

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let snapshot = model.authoritativeSnapshot(for: sessionID) {
                        contextUsageCard(snapshot)
                        configurationSection(snapshot)
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
                exporting: exporting
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
            exporting: exporting
        ))
        .accessibilityValue(snapshot.compactionQueued == true
            ? "Queued after current work"
            : (compacting || snapshot.phase == .compacting) ? "In progress" : "")
    }

    private func contextUsageCard(_ snapshot: SessionSnapshot) -> some View {
        let usage = SessionContextUsagePresentation(snapshot.contextUsage)
        let cacheRate = snapshot.stats.latestCacheHitRate.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))% hit"
        } ?? "hit rate unavailable"

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
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                ProgressView(value: percent, total: 100)
                    .tint(Color.tronEmerald)
                    .accessibilityLabel("Context used")
                    .accessibilityValue("\(Int(percent.rounded())) percent")
                Text("\(used.formatted(.number.notation(.compactName))) of \(contextWindow.formatted(.number.notation(.compactName))) · Cache \(cacheRate) · \(snapshot.stats.tokens.cacheRead.formatted(.number.notation(.compactName))) read · \(snapshot.stats.tokens.cacheWrite.formatted(.number.notation(.compactName))) write")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable:
                Text("Context usage unavailable")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text("A fresh assistant response will provide the current token-window estimate. Cache \(cacheRate) · \(snapshot.stats.tokens.cacheRead.formatted(.number.notation(.compactName))) read · \(snapshot.stats.tokens.cacheWrite.formatted(.number.notation(.compactName))) write")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.tronEmerald.opacity(0.14))

            let primary = [
                (snapshot.stats.tokens.input.formatted(.number.notation(.compactName)), "Input"),
                (snapshot.stats.tokens.output.formatted(.number.notation(.compactName)), "Output"),
                (snapshot.stats.cost.formatted(.currency(code: "USD")), "Cost"),
            ]
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 6) {
                    ForEach(0..<primary.count, id: \.self) { index in
                        metric(primary[index].0, primary[index].1)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<primary.count, id: \.self) { index in
                        metric(primary[index].0, primary[index].1)
                    }
                }
            }
        }
        .padding(14)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usage.accessibilityLabel)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
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
                            if snapshot.model == candidate.ref { Label(candidate.name, systemImage: "checkmark") }
                            else { Text(candidate.name) }
                        }
                    }
                } label: {
                    TronSettingsRow(
                        icon: "cpu",
                        title: "Model",
                        subtitle: snapshot.model.map { "\($0.provider) / \($0.id)" } ?? "Not selected",
                        accent: .tronPurple
                    )
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Model: \(snapshot.model.map { "\($0.provider) / \($0.id)" } ?? "Not selected")")
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
                    TronSettingsRow(
                        icon: "brain",
                        title: "Thinking",
                        subtitle: "Reasoning effort for this session",
                        accent: .tronPurple
                    ) {
                        Text(snapshot.thinkingLevel.capitalized)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                    }
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Thinking: \(snapshot.thinkingLevel.capitalized)")
                TronSettingsDivider(accent: .tronPurple)
                manageRow(
                    icon: "shippingbox",
                    title: "Project Resources",
                    subtitle: "Extensions, prompts, skills, context files, and tools",
                    accent: .tronTeal
                ) { destination = .projectResources }
            }
        }
    }

    private func sessionSection(_ snapshot: SessionSnapshot) -> some View {
        TronSettingsGroup("Session", detail: snapshot.cwd, accent: .tronCyan) {
            VStack(spacing: 0) {
                manageRow(icon: "pencil", title: "Rename Session", accent: .tronPurple) {
                    name = snapshot.name ?? ""
                    showRename = true
                }
                divider()
                TronSettingsRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Automatic Compaction",
                    subtitle: "Reduces context when the configured threshold is reached",
                    accent: .tronTeal
                ) {
                    Text(SessionCompactionControlPolicy.automaticStatus(snapshot.automaticCompactionEnabled))
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                }
                divider()
                manageRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Agent Context",
                    subtitle: "Instructions, current context, and active capabilities",
                    accent: .tronPurple
                ) { destination = .agentContext }
                divider()
                manageRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Session History",
                    subtitle: "Review recent history, audit changes, continue, or create a fork",
                    accent: .tronCyan
                ) { destination = .history }
                divider()
                manageRow(
                    icon: "terminal",
                    title: "Terminal",
                    subtitle: "Open or reattach the retained Mac terminal",
                    accent: .tronEmerald
                ) { destination = .terminal }
                divider()
                gitRow
                divider()
                TronSettingsRow(
                    icon: "waveform.path.ecg",
                    title: "Runtime",
                    subtitle: "\(snapshot.stats.totalMessages) messages · \(snapshot.stats.toolCalls) tool calls",
                    accent: .tronAmber
                ) {
                    Text(snapshot.phase.rawValue.capitalized)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                divider()
                manageRow(icon: "doc.richtext", title: exporting ? "Exporting…" : "HTML Export", subtitle: "Readable session archive", accent: .tronBlue) {
                    prepareExport("html")
                }
                .disabled(exporting)
                divider()
                manageRow(icon: "doc.text", title: exporting ? "Exporting…" : "JSONL Export", subtitle: "Complete canonical audit", accent: .tronBlue) {
                    prepareExport("jsonl")
                }
                .disabled(exporting)
                if let exportedURL {
                    divider()
                    ShareLink(item: exportedURL) {
                        TronSettingsRow(icon: "square.and.arrow.up", title: "Share \(exportedURL.lastPathComponent)", accent: .tronBlue)
                    }
                }
                ForEach(Array(snapshot.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    divider()
                    TronSettingsRow(
                        icon: "exclamationmark.triangle",
                        title: diagnostic.message,
                        subtitle: diagnostic.type,
                        accent: .tronAmber
                    )
                }
            }
        }
    }

    private var gitRow: some View {
        Group {
            switch gitPresentation {
            case .loading:
                TronSettingsRow(icon: "arrow.triangle.branch", title: "Current Branch", subtitle: "Checking workspace…", accent: .tronTeal) {
                    ProgressView().controlSize(.small)
                }
            case .notRepository:
                TronSettingsRow(icon: "folder", title: "Current Branch", subtitle: "Workspace is not a Git repository", accent: .tronSlate) {
                    Text("None").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                }
            case .loaded(let branch, let dirty):
                TronSettingsRow(
                    icon: "arrow.triangle.branch",
                    title: "Current Branch",
                    subtitle: dirty ? "Uncommitted changes" : "Working tree clean",
                    accent: .tronTeal
                ) {
                    Text(branch)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                }
            case .failed:
                TronSettingsRow(icon: "exclamationmark.triangle", title: "Current Branch", subtitle: "Unable to inspect this workspace", accent: .tronAmber) {
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
        guard !exporting else { return }
        exporting = true
        exportTask = Task {
            defer {
                exporting = false
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
                model.lastError = error.localizedDescription
            }
        }
    }
}

private struct AgentContextSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showInstructions = false
    @State private var showRaw = false

    private var summary: AgentContextSummary { AgentContextSummary(context: model.context) }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Label("This is the context currently assembled for the agent. Project resource inventories and schemas are kept in Project Resources.", systemImage: "info.circle")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .tronGlassSurface(accent: .tronPurple, tintOpacity: 0.08)

                    TronSettingsGroup("Instructions", detail: "Assembled runtime guidance", accent: .tronPurple) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(summary.instructionPreview)
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if summary.instructions.count > AgentContextSummary.maximumInstructionPreviewCharacters {
                                Button("Read Full Instructions") { showInstructions = true }
                                    .buttonStyle(TronActionButtonStyle(expands: false))
                            }
                        }
                        .padding(14)
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

                    DisclosureGroup(isExpanded: $showRaw) {
                        TronStructuredJSONView(value: model.context ?? .null, title: "Technical Context", accent: .tronSlate)
                            .padding(.top, 12)
                    } label: {
                        Label("Technical JSON", systemImage: "curlybraces")
                            .font(TronTypography.headline)
                            .foregroundStyle(Color.tronTextPrimary)
                    }
                    .padding(14)
                    .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.06)
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
        TronSettingsRow(icon: icon, title: title, accent: .tronCyan) {
            Text(value)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}
