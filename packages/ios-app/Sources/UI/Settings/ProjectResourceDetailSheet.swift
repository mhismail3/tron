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
    let invocation: String
    let path: String?
    let schemaSummary: String
    let guidance: String?
    let inputs: [ToolInput]

    init(value: JSONValue) {
        let object = value.objectValue ?? [:]
        let description = (object["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : ProjectResourceTextPresentation.readableDescription($0) }
        purpose = description ?? "An action available to the active model."
        invocation = object["name"]?.stringValue ?? "Resource"
        path = object["path"]?.stringValue ?? object["resolvedPath"]?.stringValue
        let parameters = object["parameters"]?.objectValue
        inputs = Self.toolInputs(parameters)
        let propertyCount = parameters?["properties"]?.objectValue?.count ?? 0
        let requiredCount = parameters?["required"]?.arrayValue?.count ?? 0
        schemaSummary = propertyCount == 0
            ? "No declared inputs"
            : "\(propertyCount) input\(propertyCount == 1 ? "" : "s") · \(requiredCount) required"
        guidance = object["promptGuidelines"]?.stringValue.map(ProjectResourceTextPresentation.readableDescription)
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
    let selection: ProjectResourceSelection
    var accentOverride: Color?
    let onDone: () -> Void
    @PresentationState private var showsResourceInfo = false

    private var presentation: ProjectResourceDetailPresentation {
        ProjectResourceDetailPresentation(value: selection.value)
    }

    private var accent: Color { accentOverride ?? selection.kind.accent }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                TronSettingsSections(alignment: .leading, spacing: TronSpacing.section, lazy: true, hidesLoneHeading: true) {
                    Text(presentation.purpose)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.10)
                    inputsSection
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
        var items = [
            TronTechnicalMetadataItem(title: "Type", value: String(selection.kind.rawValue.dropLast()), icon: selection.kind.icon),
            TronTechnicalMetadataItem(title: "Invocation", value: presentation.invocation, icon: "terminal"),
            TronTechnicalMetadataItem(title: "Source", value: object["source"]?.stringValue ?? selection.kind.rawValue, icon: "shippingbox"),
            TronTechnicalMetadataItem(title: "Availability", value: "Available for model tool calls", icon: "checkmark.seal")
        ]
        if let scope = object["scope"]?.stringValue?.capitalized {
            items.append(.init(title: "Scope", value: scope, icon: scope == "Project" ? "folder" : "person"))
        }
        if let origin = object["origin"]?.stringValue {
            items.append(.init(title: "Origin", value: origin == "top-level" ? "Top level" : origin.capitalized, icon: "point.3.connected.trianglepath.dotted"))
        }
        if let path = presentation.path, !path.isEmpty {
            items.append(.init(title: "Source file", value: path, icon: "doc.text"))
        }
        items.append(.init(title: "Inputs", value: presentation.schemaSummary, icon: "list.bullet.rectangle"))
        if let guidance = presentation.guidance, !guidance.isEmpty {
            items.append(.init(title: "Usage guidance", value: guidance, icon: "text.quote"))
        }
        return items
    }
}
