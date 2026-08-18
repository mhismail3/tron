import SwiftUI

enum ProjectResourceKind: String, CaseIterable, Identifiable {
    case extensions = "Extensions"
    case prompts = "Prompts"
    case skills = "Skills"
    case contextFiles = "Context Files"
    case tools = "Tools"

    var id: String { rawValue }
    var key: String {
        switch self {
        case .extensions: "extensions"
        case .prompts: "prompts"
        case .skills: "skills"
        case .contextFiles: "contextFiles"
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
        case .contextFiles: "doc.text"
        case .tools: "wrench.and.screwdriver"
        }
    }
    var accent: Color {
        switch self {
        case .extensions: .tronPurple
        case .prompts: .tronCyan
        case .skills: .tronEmerald
        case .contextFiles: .tronTeal
        case .tools: .tronAmber
        }
    }
    var emptyMessage: String { "No \(rawValue.lowercased()) were discovered for this project." }
    var explanation: String {
        switch self {
        case .extensions: "Code modules currently loaded into this session. Extensions can add tools, commands, providers, and lifecycle behavior."
        case .prompts: "Reusable prompt templates available as slash commands."
        case .skills: "On-demand capability guides the agent can load when a task matches."
        case .contextFiles: "Project instruction files included in the agent's context."
        case .tools: "Actions the active model can call in this session."
        }
    }
}

struct ProjectResourceSelection: Identifiable {
    let id = UUID()
    let kind: ProjectResourceKind
    let title: String
    let value: JSONValue
}

enum ProjectResourceTextPresentation {
    static func readableDescription(_ value: String) -> String {
        let characters = Array(value)
        guard characters.count > 2 else { return value }
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
        case .contextFiles:
            purpose = "Project instructions included when assembling the agent's context."
            invocation = nil
            availability = "Loaded into agent guidance"
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
            guidance = object["promptGuidelines"]?.stringValue
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
    @State private var loading = false
    @State private var reloading = false
    @State private var loadGeneration = 0
    @State private var selected: ProjectResourceSelection?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let root = model.resources?.objectValue {
                        Label("These are resolved resources actually available to this session. Open a row to inspect its source, path, capabilities, or schema.", systemImage: "info.circle")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.08)
                        ForEach(ProjectResourceKind.allCases) { kind in
                            resourceGroup(kind, values: values(for: kind, root: root))
                        }
                        let diagnostics = resourceDiagnostics(root)
                        if diagnostics != .array([]) {
                            TronSettingsGroup("Diagnostics", accent: .tronError) {
                                TronStructuredJSONView(value: diagnostics, title: "Resource Diagnostics", accent: .tronError)
                                    .padding(12)
                            }
                        }
                    } else if loading {
                        TronGlassCard(accent: .tronEmerald) {
                            TronLoadingState(label: "Loading project resources…")
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
                        HStack(spacing: 6) {
                            if loading || reloading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Reload")
                        }
                        .tronToolbarAction()
                    }
                    .disabled(loading || reloading)
                    .accessibilityValue(loading || reloading ? "In progress" : "")
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Project Resources")
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
            .task(id: model.sessionResourceRevision(for: sessionID)) { await load() }
            .sheet(item: $selected) { selection in
                ProjectResourceDetailSheet(selection: selection) {
                    selected = nil
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
    }

    private func resourceGroup(_ kind: ProjectResourceKind, values: [JSONValue]) -> some View {
        TronSettingsGroup(kind.rawValue, detail: "\(values.count) loaded · \(kind.explanation)", accent: kind.accent) {
            if values.isEmpty {
                TronSettingsRow(
                    icon: kind.icon,
                    title: "None loaded",
                    subtitle: kind.emptyMessage,
                    accent: kind.accent
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        if index > 0 { TronSettingsDivider(accent: kind.accent) }
                        Button {
                            selected = ProjectResourceSelection(
                                kind: kind,
                                title: resourceTitle(value, fallback: "Unnamed \(kind.rawValue.dropLast())"),
                                value: value
                            )
                        } label: {
                            TronSettingsRow(
                                icon: kind.icon,
                                title: resourceTitle(value, fallback: "Unnamed \(kind.rawValue.dropLast())"),
                                subtitle: resourceSubtitle(value),
                                accent: kind.accent
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project-resource-\(kind.key)-\(index)")
                    }
                }
            }
        }
    }

    private func values(for kind: ProjectResourceKind, root: [String: JSONValue]) -> [JSONValue] {
        guard let raw = root[kind.key] else { return [] }
        if let collectionKey = kind.collectionKey,
           let nested = raw.objectValue?[collectionKey]?.arrayValue { return nested }
        return raw.arrayValue ?? []
    }

    private func resourceDiagnostics(_ root: [String: JSONValue]) -> JSONValue {
        let values = ["skills", "prompts"].flatMap { key in
            root[key]?.objectValue?["diagnostics"]?.arrayValue ?? []
        }
        return .array(values)
    }

    private func resourceTitle(_ value: JSONValue, fallback: String) -> String {
        if let text = value.stringValue { return text }
        guard let object = value.objectValue else { return fallback }
        for key in ["name", "title", "path", "id"] {
            if let text = object[key]?.stringValue, !text.isEmpty {
                return key == "path" ? URL(fileURLWithPath: text).lastPathComponent : text
            }
        }
        return fallback
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

    private func reload() {
        guard !loading, !reloading else { return }
        reloading = true
        Task {
            defer { reloading = false }
            do { try await model.reloadResources(sessionID: sessionID) }
            catch is CancellationError { return }
            catch { model.lastError = error.localizedDescription }
        }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        await model.loadResources(sessionID: sessionID)
        guard generation == loadGeneration else { return }
        loading = false
    }
}

private struct ProjectResourceDetailSheet: View {
    let selection: ProjectResourceSelection
    let onDone: () -> Void

    private var presentation: ProjectResourceDetailPresentation {
        ProjectResourceDetailPresentation(kind: selection.kind, value: selection.value)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text(presentation.purpose)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: selection.kind.accent, tintOpacity: 0.10)

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
                        TronSettingsGroup("Usage Guidance", accent: selection.kind.accent) {
                            Text(guidance)
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                        sheetTitle: "\(selection.title) JSON",
                        accent: selection.kind.accent
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
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
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
