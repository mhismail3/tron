import SwiftUI
import TronMobileCore

enum ProjectResourceKind: String, CaseIterable, Identifiable, Sendable {
    case skills = "Skills"
    case subagents = "Subagents"
    case prompts = "Prompts"
    case tools = "Tools"
    case commands = "Commands"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .prompts: "text.quote"
        case .skills: "sparkles"
        case .commands: "command"
        case .tools: "wrench.and.screwdriver"
        case .subagents: "person.2"
        }
    }
    @MainActor var accent: Color {
        switch self {
        case .prompts: .tronPurple
        case .skills: .tronCyan
        case .commands: ChatSemanticPillRole.command.accent
        case .tools: .tronAmber
        case .subagents: .tronSubagent
        }
    }
}

struct ProjectResourceSelection: Identifiable {
    let id = UUID()
    let kind: ProjectResourceKind
    let title: String
    let value: JSONValue

    var commandInfo: CommandInfo? {
        guard kind == .prompts || kind == .skills || kind == .commands,
              let object = value.objectValue,
              let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        let source: CommandInfoSource = switch kind {
        case .skills: .skill
        case .commands: .extension
        default: .prompt
        }
        return CommandInfo(
            name: kind == .skills ? "skill:\(name)" : name,
            description: object["description"]?.stringValue,
            argumentHint: object["argumentHint"]?.stringValue,
            source: source,
            sourcePath: object["path"]?.stringValue ?? object["resolvedPath"]?.stringValue,
            resourceSource: object["source"]?.stringValue,
            resourceScope: object["scope"]?.stringValue.flatMap(CommandInfoResourceScope.init(rawValue:)),
            resourceOrigin: object["origin"]?.stringValue.flatMap(CommandInfoResourceOrigin.init(rawValue:))
        )
    }

}

enum ProjectResourceTextPresentation {
    static func readableDescription(_ value: String) -> String {
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
    struct ToolInput: Equatable, Identifiable {
        let name: String
        let type: String?
        let required: Bool
        let detail: String?
        var id: String { name }
    }

    let purpose: String
    let invocation: String?
    let availability: String?
    let path: String?
    let model: String?
    let tools: [String]
    let commands: [String]
    let schemaSummary: String?
    let guidance: String?
    let inputs: [ToolInput]

    init(kind: ProjectResourceKind, value: JSONValue) {
        let object = value.objectValue ?? [:]
        let name = object["name"]?.stringValue ?? "Resource"
        let rawDescription = object["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = rawDescription.flatMap { value in
            value.isEmpty ? nil : ProjectResourceTextPresentation.readableDescription(value)
        }
        path = object["path"]?.stringValue ?? object["resolvedPath"]?.stringValue
        inputs = kind == .tools ? Self.toolInputs(object["parameters"]?.objectValue) : []

        switch kind {
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
        case .commands:
            purpose = description ?? "A command registered by a loaded extension."
            invocation = "/\(name)"
            availability = "Registered by a loaded extension"
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
        case .subagents:
            purpose = description ?? "An agent definition available for delegated work."
            invocation = nil
            availability = "Available for delegation"
            tools = []
            commands = []
            schemaSummary = nil
            guidance = nil
        }
        model = kind == .subagents ? object["model"]?.stringValue : nil
    }

    private static func toolInputs(_ parameters: [String: JSONValue]?) -> [ToolInput] {
        let required = Set(parameters?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let properties = parameters?["properties"]?.objectValue ?? [:]
        return properties.map { name, value in
            let schema = value.objectValue
            let type = schema?["type"]?.stringValue
                ?? schema?["type"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " | ")
                ?? (schema?["anyOf"] != nil || schema?["oneOf"] != nil ? "one of several" : nil)
            let detail = schema?["description"]?.stringValue
                .map(ProjectResourceTextPresentation.readableDescription)
                .flatMap { $0.isEmpty ? nil : $0 }
            return ToolInput(name: name, type: type, required: required.contains(name), detail: detail)
        }.sorted {
            $0.required != $1.required ? $0.required : $0.name < $1.name
        }
    }
}

struct ProjectResourceDetailSheet: View {
    let sessionID: String
    let selection: ProjectResourceSelection
    var accentOverride: Color?
    let onDone: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var detail: CommandDetail?
    @PresentationState private var subagentDetail: SubagentResourceDetail?
    @PresentationState private var loadError: String?
    @PresentationState private var loadRevision = 0
    @PresentationState private var detailGeneration = 0
    @PresentationState private var loadedIdentity: String?
    @PresentationState private var showsResourceInfo = false
    @PresentationState private var reading: ProjectResourceReading?

    private var presentation: ProjectResourceDetailPresentation {
        ProjectResourceDetailPresentation(kind: selection.kind, value: selection.value)
    }

    private var accent: Color { accentOverride ?? selection.kind.accent }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                TronSettingsSections(alignment: .leading, spacing: TronSpacing.section, lazy: true, hidesLoneHeading: true) {
                    if !resolvedPurpose.isEmpty {
                        Text(resolvedPurpose)
                            .font(TronTypography.body)
                            .foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronGlassSurface(accent: accent, tintOpacity: 0.10)
                    }
                    if selection.kind == .tools {
                        inputsSection
                    } else {
                        ProjectResourceContentSection(selection: selection, detail: detail, subagentDetail: subagentDetail,
                                                      loadError: loadError, accent: accent,
                                                      retry: { loadRevision &+= 1 }, read: { reading = $0 })
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TronSheetInfoButton(accessibilityLabel: "Resource Info", accent: accent) { showsResourceInfo = true }
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: selection.title, accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .tint(accent)
        }
        .tronManagedSheet(item: $reading, identity: { "project-resource-reading.\($0.id)" }) { ProjectResourceReader(reading: $0) }
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
        guard let description = (detail?.description ?? subagentDetail?.description)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
            return presentation.purpose
        }
        return ProjectResourceTextPresentation.readableDescription(description)
    }

    private var inputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TronTechnicalSectionLabel("Inputs").containerValue(\.tronSettingsSection, false)
            VStack(alignment: .leading, spacing: 12) {
                if presentation.inputs.isEmpty {
                    Text("This tool takes no inputs.")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                ForEach(presentation.inputs) { input in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: input.name)
                                .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronTextPrimary)
                            Text([input.type, input.required ? "required" : "optional"].compactMap { $0 }.joined(separator: " · "))
                                .font(TronTypography.sans(size: TronTypography.sizeSecondary))
                                .foregroundStyle(input.required ? accent : Color.tronTextMuted)
                        }
                        if let detail = input.detail {
                            Text(detail)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
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
        if let model = presentation.model {
            items.append(.init(title: "Model", value: model, icon: "cpu"))
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
        if let bytes = detail?.contentBytes ?? subagentDetail?.contentBytes {
            items.append(.init(title: "Content size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file), icon: "internaldrive"))
        }
        return items
    }

    private var loadIdentity: String {
        "\(selection.id):\(model.sessionResourceRevision(for: sessionID))"
    }

    private func loadDetail() async {
        if loadedIdentity == loadIdentity, detail != nil || subagentDetail != nil, loadError == nil { return }
        detailGeneration &+= 1
        let generation = detailGeneration
        let identity = loadIdentity
        detail = nil
        subagentDetail = nil
        loadError = nil
        if selection.kind == .tools,
           selection.value.objectValue?["description"]?.stringValue != nil,
           selection.value.objectValue?["parameters"] != nil {
            loadedIdentity = identity
            return
        }
        let subagentName = selection.kind == .subagents ? selection.value.objectValue?["name"]?.stringValue : nil
        let command = selection.commandInfo
        guard subagentName != nil || command != nil else { return }
        do {
            if let subagentName {
                let loaded = try await model.subagentDetail(sessionID: sessionID, name: subagentName)
                guard generation == detailGeneration,
                      !Task.isCancelled,
                      presentationActivity.allowsPresentationPublication else { return }
                subagentDetail = loaded
            } else if let command {
                let loaded = try await model.commandDetail(sessionID: sessionID, command: command)
                guard generation == detailGeneration,
                      !Task.isCancelled,
                      presentationActivity.allowsPresentationPublication else { return }
                detail = loaded
            }
            loadedIdentity = identity
        } catch is CancellationError {
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

