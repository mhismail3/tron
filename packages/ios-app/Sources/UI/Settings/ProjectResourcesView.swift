import SwiftUI

enum ProjectResourceKind: String, CaseIterable, Identifiable, Sendable {
    case extensions = "Extensions"
    case prompts = "Prompts"
    case skills = "Skills"
    case tools = "Tools"

    var id: String { rawValue }
    var key: String {
        switch self {
        case .extensions: "extensions"
        case .prompts: "prompts"
        case .skills: "skills"
        case .tools: "tools"
        }
    }
    var collectionKey: String? {
        switch self {
        case .prompts: "prompts"
        case .skills: "skills"
        default: nil
        }
    }
    var icon: String {
        switch self {
        case .extensions: "shippingbox"
        case .prompts: "text.quote"
        case .skills: "sparkles"
        case .tools: "wrench.and.screwdriver"
        }
    }
    var accent: Color {
        switch self {
        case .extensions: .tronPurple
        case .prompts: .tronCyan
        case .skills: .tronEmerald
        case .tools: .tronAmber
        }
    }
    var emptyMessage: String { "No \(rawValue.lowercased()) were discovered for this project." }
    var explanation: String {
        switch self {
        case .extensions: "Code modules currently loaded into this session. Extensions can add tools, commands, providers, and lifecycle behavior."
        case .prompts: "Reusable prompt templates available as slash commands."
        case .skills: "On-demand capability guides the agent can load when a task matches."
        case .tools: "Actions the active model can call in this session."
        }
    }
}

struct ProjectResourceSelection: Identifiable {
    let id = UUID()
    let kind: ProjectResourceKind
    let title: String
    let value: JSONValue

    var promptCommand: CommandInfo? {
        guard kind == .prompts,
              let object = value.objectValue,
              let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        return CommandInfo(
            name: name,
            description: object["description"]?.stringValue,
            argumentHint: object["argumentHint"]?.stringValue,
            source: .prompt,
            sourcePath: object["path"]?.stringValue,
            resourceSource: object["source"]?.stringValue,
            resourceScope: object["scope"]?.stringValue.flatMap(CommandInfo.ResourceScope.init(rawValue:))
        )
    }
}

private struct ProjectResourceOverviewRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let value: JSONValue
}

private struct ProjectResourceOverviewSection: Identifiable, Equatable, Sendable {
    var id: ProjectResourceKind { kind }
    let kind: ProjectResourceKind
    let rows: [ProjectResourceOverviewRow]
}

enum ProjectResourceTextPresentation {
    static func readableDescription(_ value: String) -> String {
        // Resource descriptions may arrive from Markdown/front matter with
        // hard wraps. Collapse all producer whitespace before SwiftUI lays the
        // text out so wrapping happens only at the card's actual width.
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let characters = Array(normalized)
        guard characters.count > 2 else { return normalized }
        return characters.indices.map { index in
            guard characters[index] == "-",
                  index > characters.startIndex,
                  index < characters.index(before: characters.endIndex),
                  characters[characters.index(before: index)].isLetter || characters[characters.index(before: index)].isNumber,
                  characters[characters.index(after: index)].isLetter || characters[characters.index(after: index)].isNumber
            else { return String(characters[index]) }
            return "‑"
        }.joined()
    }
}

struct ProjectResourceDetailPresentation: Equatable {
    let purpose: String
    let invocation: String?
    let availability: String?
    let scopeAndSource: String?
    let path: String?
    let tools: [String]
    let commands: [String]
    let schemaSummary: String?
    let guidance: String?

    init(kind: ProjectResourceKind, value: JSONValue) {
        let object = value.objectValue ?? [:]
        let name = object["name"]?.stringValue ?? "Resource"
        let rawDescription = object["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = rawDescription.flatMap { value in
            value.isEmpty ? nil : ProjectResourceTextPresentation.readableDescription(value)
        }
        path = object["path"]?.stringValue ?? object["resolvedPath"]?.stringValue
        let scope = object["scope"]?.stringValue?.capitalized
        let source = object["source"]?.stringValue
        if let scope, let source { scopeAndSource = "\(scope) · \(source)" }
        else { scopeAndSource = scope ?? source }

        switch kind {
        case .extensions:
            purpose = description ?? "A loaded extension that can add commands, tools, and session behavior."
            tools = Self.strings(object["tools"])
            commands = Self.strings(object["commands"])
            invocation = nil
            availability = "Loaded for this session"
            schemaSummary = nil
            guidance = nil
        case .prompts:
            purpose = description ?? "A reusable prompt template."
            let rawHint = object["argumentHint"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = rawHint.flatMap { $0.isEmpty ? nil : $0 }
            invocation = "/\(name)" + (hint.map { " \($0)" } ?? "")
            availability = "Available as a slash command"
            tools = []
            commands = []
            schemaSummary = nil
            guidance = nil
        case .skills:
            purpose = description ?? "Guidance the agent can load for matching work."
            invocation = nil
            availability = object["disableModelInvocation"]?.boolValue == true
                ? "Manual invocation only"
                : "Available to the agent on demand"
            tools = []
            commands = []
            schemaSummary = nil
            guidance = nil
        case .tools:
            purpose = description ?? "An action available to the active model."
            invocation = name
            availability = "Available for model tool calls"
            tools = []
            commands = []
            let parameters = object["parameters"]?.objectValue
            let propertyCount = parameters?["properties"]?.objectValue?.count ?? 0
            let requiredCount = parameters?["required"]?.arrayValue?.count ?? 0
            schemaSummary = propertyCount == 0
                ? "No declared inputs"
                : "\(propertyCount) input\(propertyCount == 1 ? "" : "s") · \(requiredCount) required"
            guidance = object["promptGuidelines"]?.stringValue.map(ProjectResourceTextPresentation.readableDescription)
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

struct ProjectResourcesView: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loading = false
    @State private var reloading = false
    @State private var loadGeneration = 0
    @State private var selected: ProjectResourceSelection?
    @State private var overviewSections: [ProjectResourceOverviewSection] = []
    @State private var diagnostics: JSONValue = .array([])

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.resources?.objectValue != nil {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(overviewSections) { section in
                                resourceGroup(section)
                            }
                        }
                        .tronSettingsCaption("These are resolved resources actually available to this session. Open a row to inspect its source, path, capabilities, or schema.")
                        if diagnostics != .array([]) {
                            TronSettingsGroup("Diagnostics", accent: .tronError, surfaceStyle: .scrollOptimized) {
                                TronStructuredJSONView(value: diagnostics, title: "Resource Diagnostics", accent: .tronError)
                                    .padding(12)
                            }
                            .environment(\.tronSettingsVisualTheme, nil)
                        }
                    } else if loading {
                        TronGlassCard(accent: .tronSessionTeal) {
                            TronLoadingState(label: "Loading project resources…", accent: .tronSessionTeal)
                                .padding(18)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        ContentUnavailableView(
                            "Resources Unavailable",
                            systemImage: "shippingbox",
                            description: Text("Reload the session resources and try again.")
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reload) {
                        TronToolbarTextLabel(
                            "Reload",
                            systemImage: "arrow.clockwise",
                            isWorking: loading || reloading
                        )
                        .tronToolbarAction(accent: .tronSessionTeal)
                    }
                    .disabled(loading || reloading)
                    .accessibilityValue(loading || reloading ? "In progress" : "")
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Project Resources", accent: .tronSessionTeal)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronSessionTeal)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task(id: PresentationActivityTaskID(
                source: model.sessionResourceRevision(for: sessionID),
                presentationActive: presentationActivity.allowsPresentationPublication
            )) {
                guard presentationActivity.allowsPresentationPublication else { return }
                if overviewSections.isEmpty { installOverview() }
                await load()
            }
            .tronManagedSheet(
                item: $selected,
                identity: { _ in "settings.project-resource-detail" }
            ) { selection in
                ProjectResourceDetailSheet(sessionID: sessionID, selection: selection) {
                    selected = nil
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
        .tint(Color.tronSessionTeal)
    }

    private func resourceGroup(_ section: ProjectResourceOverviewSection) -> some View {
        let kind = section.kind
        return TronSettingsGroup(
            kind.rawValue,
            detail: "\(section.rows.count) loaded · \(kind.explanation)",
            accent: kind.accent,
            surfaceStyle: .scrollOptimized
        ) {
            if section.rows.isEmpty {
                TronSettingsRow(
                    icon: kind.icon,
                    title: "None loaded",
                    subtitle: kind.emptyMessage,
                    accent: kind.accent
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { TronSettingsDivider(accent: kind.accent) }
                        Button {
                            selected = ProjectResourceSelection(
                                kind: kind,
                                title: row.title,
                                value: row.value
                            )
                        } label: {
                            TronSettingsRow(
                                icon: kind.icon,
                                title: row.title,
                                subtitle: row.subtitle,
                                subtitleLineLimit: 1,
                                accent: kind.accent
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project-resource-\(kind.key)-\(index)")
                    }
                }
            }
        }
        // Resource kinds retain their own accents; the teal theme belongs to
        // this destination's navigation chrome and generic session surfaces.
        .environment(\.tronSettingsVisualTheme, nil)
    }

    private func resourceDiagnostics(_ root: [String: JSONValue]) -> JSONValue {
        let values = ["skills", "prompts"].flatMap { key in
            root[key]?.objectValue?["diagnostics"]?.arrayValue ?? []
        }
        return .array(values)
    }

    private func resourceSubtitle(_ value: JSONValue) -> String? {
        guard let object = value.objectValue else { return nil }
        if let description = object["description"]?.stringValue, !description.isEmpty {
            return ProjectResourceTextPresentation.readableDescription(description)
        }
        let scope = object["scope"]?.stringValue?.capitalized
        let source = object["source"]?.stringValue
        if let scope, let source { return "\(scope) · \(source)" }
        return scope ?? object["path"]?.stringValue
    }

    private func installOverview() {
        guard let root = model.resources?.objectValue else {
            overviewSections = []
            diagnostics = .array([])
            return
        }
        overviewSections = ProjectResourceKind.allCases.map { kind in
            let raw = root[kind.key]
            let values: [JSONValue]
            if let collectionKey = kind.collectionKey,
               let nested = raw?.objectValue?[collectionKey]?.arrayValue {
                values = nested
            } else {
                values = raw?.arrayValue ?? []
            }
            let rows = values.enumerated().map { index, value in
                let title = ProjectResourceTitlePresentation.title(kind: kind, value: value)
                let semanticID = value.objectValue?["id"]?.stringValue
                    ?? value.objectValue?["path"]?.stringValue
                    ?? value.objectValue?["name"]?.stringValue
                    ?? title
                return ProjectResourceOverviewRow(
                    id: "\(kind.key):\(semanticID):\(index)",
                    title: title,
                    subtitle: resourceSubtitle(value),
                    value: value
                )
            }
            return ProjectResourceOverviewSection(kind: kind, rows: rows)
        }
        diagnostics = resourceDiagnostics(root)
    }

    private func reload() {
        guard !loading, !reloading else { return }
        reloading = true
        // Reload changes runtime resources. Keep that admitted mutation alive;
        // its authoritative resource revision drives the disposable read task.
        Task {
            defer { reloading = false }
            do { try await model.reloadResources(sessionID: sessionID) }
            catch is CancellationError { return }
            catch { model.presentError(error) }
        }
    }

    private func load() async {
        guard presentationActivity.allowsPresentationPublication else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        defer {
            if generation == loadGeneration, !Task.isCancelled,
               presentationActivity.allowsPresentationPublication { loading = false }
        }
        await model.loadResources(sessionID: sessionID)
        guard !Task.isCancelled,
              presentationActivity.allowsPresentationPublication,
              generation == loadGeneration else { return }
        installOverview()
    }
}

struct ProjectResourceDetailSheet: View {
    let sessionID: String
    let selection: ProjectResourceSelection
    let onDone: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var promptDetail: CommandResourceDetail?
    @State private var promptLoadError: String?
    @State private var loadRevision = 0

    private var presentation: ProjectResourceDetailPresentation {
        ProjectResourceDetailPresentation(kind: selection.kind, value: selection.value)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    TronSettingsCaption(presentation.purpose)

                    if selection.kind == .prompts {
                        promptContent
                    }

                    if presentation.invocation != nil
                        || presentation.availability != nil
                        || presentation.scopeAndSource != nil
                        || presentation.schemaSummary != nil {
                        TronSettingsGroup("At a Glance", accent: selection.kind.accent) {
                            VStack(spacing: 0) {
                                detailRows
                            }
                        }
                    }

                    if !presentation.tools.isEmpty || !presentation.commands.isEmpty {
                        TronSettingsGroup("Capabilities", accent: selection.kind.accent) {
                            VStack(alignment: .leading, spacing: 14) {
                                if !presentation.tools.isEmpty {
                                    capabilityCollection(
                                        title: "Tools",
                                        icon: "wrench.and.screwdriver",
                                        values: presentation.tools
                                    )
                                }
                                if !presentation.tools.isEmpty && !presentation.commands.isEmpty {
                                    TronSettingsDivider(accent: selection.kind.accent)
                                }
                                if !presentation.commands.isEmpty {
                                    capabilityCollection(
                                        title: "Commands",
                                        icon: "command",
                                        values: presentation.commands.map { "/" + $0 }
                                    )
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let guidance = presentation.guidance, !guidance.isEmpty {
                        VStack(alignment: .leading, spacing: TronSpacing.md) {
                            Text("Usage Guidance")
                                .font(TronTypography.sheetSectionHeader)
                                .foregroundStyle(Color.tronTextPrimary)
                                .accessibilityAddTraits(.isHeader)
                            TronSettingsCaption(guidance)
                        }
                    }

                    if let path = presentation.path {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SOURCE FILE")
                                .font(TronTypography.sheetSectionHeader)
                                .foregroundStyle(Color.tronTextMuted)
                            Label(path, systemImage: "folder")
                                .font(TronTypography.codeContent)
                                .foregroundStyle(Color.tronTextSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: selection.kind.accent, tintOpacity: 0.06)
                    }

                    TronTechnicalJSONRow(
                        value: selection.value,
                        sheetTitle: "\(selection.title) JSON"
                    )
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: selection.title, accent: selection.kind.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(selection.kind.accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .tint(selection.kind.accent)
        }
        .tronSettingsVisualTheme(accent: selection.kind.accent)
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task(id: PresentationActivityTaskID(
            source: "\(selection.id):\(model.sessionResourceRevision(for: sessionID)):\(loadRevision)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await loadPromptContent()
        }
    }

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            TronTechnicalSectionLabel("Content")
            Group {
                if let promptLoadError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(promptLoadError)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                        Button("Try Again", systemImage: "arrow.clockwise") { loadRevision &+= 1 }
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(selection.kind.accent)
                    }
                } else if let promptDetail {
                    ProjectResourcePromptContent(detail: promptDetail)
                } else {
                    TronLoadingState(label: "Loading prompt content…", accent: selection.kind.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronScrollSurface(accent: selection.kind.accent, cornerRadius: 16, tintOpacity: 0.06)
        }
    }

    private func loadPromptContent() async {
        guard selection.kind == .prompts else { return }
        promptLoadError = nil
        guard let command = selection.promptCommand else {
            promptLoadError = "This prompt has no available content identity. Reload Project Resources and try again."
            return
        }
        do {
            // The resource catalog intentionally contains metadata only. Read
            // the loaded template on demand, never an arbitrary Mac file path.
            let detail = try await model.commandDetail(sessionID: sessionID, command: command)
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication else { return }
            promptDetail = detail
        } catch is CancellationError {
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication else { return }
            promptLoadError = "Prompt content is unavailable while the session is disconnected or busy. Try again when it is ready."
        } catch {
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication else { return }
            promptLoadError = error.localizedDescription
        }
    }

    private func capabilityCollection(
        title: String,
        icon: String,
        values: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("\(title) · \(values.count)", systemImage: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selection.kind.accent.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
            }
        }
    }

    private var detailRows: some View {
        let rows: [(icon: String, title: String, value: String)] = [
            presentation.invocation.map { ("command", "Invocation", $0) },
            presentation.availability.map { ("checkmark.seal", "Availability", $0) },
            presentation.scopeAndSource.map { ("scope", "Scope & Source", $0) },
            presentation.schemaSummary.map { ("list.bullet.rectangle", "Inputs", $0) },
        ].compactMap { $0 }
        return ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            if index > 0 { TronSettingsDivider(accent: selection.kind.accent) }
            detailRow(icon: row.icon, title: row.title, value: row.value)
        }
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        TronSettingsRow(icon: icon, title: title, accent: selection.kind.accent) {
            Text(value)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
