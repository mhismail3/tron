import SwiftUI

private enum ProjectResourceKind: String, CaseIterable, Identifiable {
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

private struct ProjectResourceSelection: Identifiable {
    let id = UUID()
    let kind: ProjectResourceKind
    let title: String
    let value: JSONValue
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
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            resourceSummary(selection.value, kind: selection.kind)
                            TronStructuredJSONView(
                                value: selection.value,
                                title: selection.title,
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
                            Button { selected = nil } label: {
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
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resourceSummary(_ value: JSONValue, kind: ProjectResourceKind) -> some View {
        if let object = value.objectValue {
            if let description = object["description"]?.stringValue, !description.isEmpty {
                Text(description)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(accent: kind.accent, tintOpacity: 0.10)
            }
            if let path = object["path"]?.stringValue {
                Label(path, systemImage: "folder")
                    .font(TronTypography.codeContent)
                    .foregroundStyle(Color.tronTextSecondary)
                    .textSelection(.enabled)
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
        if let description = object["description"]?.stringValue, !description.isEmpty { return description }
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
