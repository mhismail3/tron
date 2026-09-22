import SwiftUI

enum ProjectResourceKind: String, CaseIterable, Identifiable, Sendable {
    case prompts = "Prompts"
    case skills = "Skills"
    case tools = "Tools"
    case extensions = "Extensions"

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
    /// Prompt and skill accents are shared with the chat composer; other
    /// Project Resources categories retain their existing destination colors.
    @MainActor var accent: Color {
        switch self {
        case .extensions: .tronPurple
        case .prompts: ChatSemanticPillRole.prompt.accent
        case .skills: .tronCyan
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

    var commandInfo: CommandInfo? {
        guard kind == .prompts || kind == .skills,
              let object = value.objectValue,
              let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        let source: CommandInfo.Source = kind == .skills ? .skill : .prompt
        return CommandInfo(
            name: kind == .skills ? "skill:\(name)" : name,
            description: object["description"]?.stringValue,
            argumentHint: object["argumentHint"]?.stringValue,
            source: source,
            sourcePath: object["path"]?.stringValue ?? object["resolvedPath"]?.stringValue,
            resourceSource: object["source"]?.stringValue,
            resourceScope: object["scope"]?.stringValue.flatMap(CommandInfo.ResourceScope.init(rawValue:)),
            resourceOrigin: object["origin"]?.stringValue.flatMap(CommandInfo.ResourceOrigin.init(rawValue:))
        )
    }

}

private struct ProjectResourceOverviewRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let value: JSONValue
    let resourceScope: CommandInfo.ResourceScope?
    let resourceOrigin: CommandInfo.ResourceOrigin?
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
                        TronPlaceholderState(
                            title: "Resources Unavailable",
                            detail: "Reload the session resources and try again.",
                            icon: "shippingbox",
                            accent: .tronSessionTeal
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
                            ) {
                                ComposerResourceBadges(
                                    origin: row.resourceOrigin,
                                    scope: row.resourceScope,
                                    accent: kind.accent
                                )
                            }
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
                    value: value,
                    resourceScope: value.objectValue?["scope"]?.stringValue.flatMap(CommandInfo.ResourceScope.init(rawValue:)),
                    resourceOrigin: value.objectValue?["origin"]?.stringValue.flatMap(CommandInfo.ResourceOrigin.init(rawValue:))
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
    @State private var detail: CommandResourceDetail?
    @State private var loadError: String?
    @State private var loadRevision = 0
    @State private var detailGeneration = 0
    @State private var loadedIdentity: String?
    @State private var showsResourceInfo = false

    private var presentation: ProjectResourceDetailPresentation {
        ProjectResourceDetailPresentation(kind: selection.kind, value: selection.value)
    }

    private var accent: Color { selection.kind.accent }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    if !resolvedPurpose.isEmpty {
                        Text(resolvedPurpose)
                            .font(TronTypography.body)
                            .foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronGlassSurface(accent: accent, tintOpacity: 0.10)
                    }
                    contentSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsResourceInfo = true } label: {
                        Image(systemName: "info.circle")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Resource Info")
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: selection.title, accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .tint(accent)
        }
        .tronManagedSheet(isPresented: $showsResourceInfo, identity: "project-resource-info.\(selection.id)") {
            ComposerResourceInfoSheet(
                items: metadata,
                accent: accent,
                technicalValue: selection.value,
                technicalTitle: "\(selection.title) JSON"
            )
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: accent)
        .task(id: PresentationActivityTaskID(
            source: "\(selection.id):\(model.sessionResourceRevision(for: sessionID)):\(loadRevision)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await loadDetail()
        }
    }

    private var resolvedPurpose: String {
        guard let description = detail?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
            return presentation.purpose
        }
        return ProjectResourceTextPresentation.readableDescription(description)
    }

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TronTechnicalSectionLabel("Content")
            Group {
                if let detail, let content = detail.content, !content.isEmpty {
                    let preview = ComposerResourceContentPresentation.preview(
                        content,
                        source: selection.commandInfo?.source ?? .extension,
                        sourceTruncated: detail.contentTruncated == true
                    )
                    ComposerResourceContentBody(
                        preview: preview,
                        source: selection.commandInfo?.source ?? .extension
                    )
                } else if detail != nil {
                    Text("This resource has no body content.")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                } else if let loadError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(loadError)
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                        Button("Try Again", systemImage: "arrow.clockwise") { loadRevision &+= 1 }
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                } else if selection.commandInfo == nil {
                    Text("This resource does not expose body content.")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                } else {
                    TronLoadingState(label: "Loading resource content…", accent: accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronScrollSurface(accent: accent, cornerRadius: 16, tintOpacity: 0.06)
        }
    }

    private var metadata: [TronTechnicalMetadataItem] {
        let object = selection.value.objectValue ?? [:]
        let command = selection.commandInfo
        let source = detail?.resourceSource ?? command?.resourceSource ?? object["source"]?.stringValue ?? selection.kind.rawValue
        var items = [
            TronTechnicalMetadataItem(title: "Type", value: String(selection.kind.rawValue.dropLast()), icon: selection.kind.icon),
            TronTechnicalMetadataItem(title: "Source", value: source, icon: "shippingbox")
        ]
        if let command {
            let name = detail?.name ?? command.name
            let invocation = command.source == .skill ? "@\(name.replacingOccurrences(of: "skill:", with: ""))" : "/\(name)"
            items.insert(.init(title: "Invocation", value: invocation, icon: "terminal"), at: 1)
        } else if let invocation = presentation.invocation {
            items.insert(.init(title: "Invocation", value: invocation, icon: "terminal"), at: 1)
        }
        if let availability = presentation.availability {
            items.append(.init(title: "Availability", value: availability, icon: "checkmark.seal"))
        }
        let scope = detail?.resourceScope?.rawValue.capitalized ?? object["scope"]?.stringValue?.capitalized
        if let scope {
            items.append(.init(title: "Scope", value: scope, icon: scope == "Project" ? "folder" : "person"))
        }
        let origin = detail?.resourceOrigin?.rawValue ?? command?.resourceOrigin?.rawValue ?? object["origin"]?.stringValue
        if let origin {
            items.append(.init(title: "Origin", value: origin == "top-level" ? "Top level" : origin.capitalized, icon: "point.3.connected.trianglepath.dotted"))
        }
        if let path = detail?.sourcePath ?? presentation.path, !path.isEmpty {
            items.append(.init(title: "Source file", value: path, icon: "doc.text"))
        }
        if !presentation.tools.isEmpty {
            items.append(.init(title: "Tools", value: presentation.tools.joined(separator: ", "), icon: "wrench.and.screwdriver"))
        }
        if !presentation.commands.isEmpty {
            items.append(.init(title: "Commands", value: presentation.commands.map { "/\($0)" }.joined(separator: ", "), icon: "command"))
        }
        if let schema = presentation.schemaSummary {
            items.append(.init(title: "Inputs", value: schema, icon: "list.bullet.rectangle"))
        }
        if let guidance = presentation.guidance, !guidance.isEmpty {
            items.append(.init(title: "Usage guidance", value: guidance, icon: "text.quote"))
        }
        if let argumentHint = detail?.argumentHint ?? command?.argumentHint, !argumentHint.isEmpty {
            items.append(.init(title: "Arguments", value: argumentHint, icon: "text.badge.plus"))
        }
        if let bytes = detail?.contentBytes {
            items.append(.init(title: "Content size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file), icon: "internaldrive"))
        }
        return items
    }

    /// Identity of the reader this sheet displays. A completed detail for this
    /// exact selection/revision stays mounted across a cover, so returning from
    /// the nested Info sheet neither blanks content nor refetches the source.
    private var loadIdentity: String {
        "\(selection.id):\(model.sessionResourceRevision(for: sessionID))"
    }

    private func loadDetail() async {
        if loadedIdentity == loadIdentity, detail != nil, loadError == nil { return }
        detailGeneration &+= 1
        let generation = detailGeneration
        let identity = loadIdentity
        detail = nil
        loadError = nil
        guard let command = selection.commandInfo else { return }
        do {
            let loaded = try await model.commandDetail(sessionID: sessionID, command: command)
            guard generation == detailGeneration,
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication else { return }
            detail = loaded
            loadedIdentity = identity
        } catch is CancellationError {
            // A rejected live-session read is not a cancelled presentation.
            // Settle it so disconnected/busy sessions offer retry, not a spinner.
            guard generation == detailGeneration,
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication else { return }
            loadError = "Resource content is unavailable while the session is disconnected or busy. Try again when it is ready."
            loadedIdentity = identity
        } catch {
            guard generation == detailGeneration,
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication else { return }
            loadError = error.localizedDescription
            loadedIdentity = identity
        }
    }
}
