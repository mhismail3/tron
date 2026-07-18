import Foundation

/// Revision-pinned catalog for precompiled SwiftUI components and modifiers.
enum NativeUICatalog {
    static let schemaVersion = "tron.native-ui.definition.v1"
    static let a2uiVersion = "v0.9.1"
    static let id = "https://tron.local/native-ui/catalogs/sheet/v1"
    static let revision: UInt64 = 1

    static let maxPayloadBytes = 64 * 1024
    static let maxDepth = 8
    static let maxComponents = 200
    static let maxActions = 50
    static let maxTextBytes = 16 * 1024
    static let maxModifiersPerComponent = 32
    static let maxStagedBatches = 4
    static let maxMessagesPerBatch = 256

    static let components: Set<String> = [
        "Surface", "Navigation", "Scroll", "Row", "Column", "Overlay", "Grid",
        "AdaptiveColumns", "List", "Section", "GlassCard", "Divider", "Spacer",
        "Text", "Image", "Icon", "Badge", "Progress", "EmptyState", "Button",
        "Toggle", "Slider", "Stepper", "TextField", "SecureField", "ChoicePicker",
        "Menu", "ResourcePicker", "NativeSlot",
    ]

    static let modifiers: Set<String> = [
        "frame", "padding", "offset", "fixedSize", "aspectRatio", "font", "fontWeight",
        "fontDesign", "foregroundStyle", "tint", "opacity", "background", "glassEffect",
        "clipShape", "cornerRadius", "shadow", "overlay", "stroke", "lineLimit",
        "multilineTextAlignment", "lineSpacing", "textSelection", "monospacedDigit",
        "disabled", "hidden", "contentShape", "buttonStyle", "accessibility", "transition",
        "animation", "sizeClass",
    ]

    static let clientFunctions: Set<NativeUIClientFunctionIdentity> = [
        .init(name: "dismiss", revision: 1),
        .init(name: "navigate", revision: 1),
        .init(name: "copy", revision: 1),
        .init(name: "openUrl", revision: 1),
        .init(name: "resourcePicker", revision: 1),
        .init(name: "filePicker", revision: 1),
        .init(name: "camera", revision: 1),
    ]

    static func allowedProperties(for component: String) -> Set<String> {
        var common: Set<String> = ["modifiers", "visible", "accessibilityLabel"]
        let specific: Set<String> = switch component {
        case "Surface": ["child"]
        case "Navigation": ["child", "title"]
        case "Scroll": ["child", "axis", "showsIndicators"]
        case "Row", "Column", "Overlay": ["children", "spacing", "alignment"]
        case "Grid": ["children", "columns", "spacing"]
        case "AdaptiveColumns": ["children", "minimumColumnWidth", "spacing"]
        case "List": ["children", "spacing"]
        case "Section": ["children", "title", "icon", "footer"]
        case "GlassCard": ["children", "accent", "interactive"]
        case "Divider": ["orientation"]
        case "Spacer": ["minimumLength"]
        case "Text": ["text", "label", "icon", "style", "selectable", "format"]
        case "Image": ["name", "url", "contentMode"]
        case "Icon": ["systemName", "size", "tone"]
        case "Badge": ["text", "tone"]
        case "Progress": ["value", "total", "label"]
        case "EmptyState": ["title", "message", "systemImage"]
        case "Button": ["label", "value", "icon", "role", "action"]
        case "Toggle": ["label", "value", "icon", "action"]
        case "Slider": ["label", "value", "icon", "minimum", "maximum", "step", "format", "commit", "action"]
        case "Stepper": ["label", "value", "icon", "minimum", "maximum", "step", "action"]
        case "TextField", "SecureField": ["label", "value", "placeholder", "action"]
        case "ChoicePicker": ["label", "value", "options", "action"]
        case "Menu": ["label", "icon", "children"]
        case "ResourcePicker": ["label", "kind", "selected", "action"]
        case "NativeSlot": ["name", "arguments"]
        default: []
        }
        common.formUnion(specific)
        return common
    }

    static func modifier(_ name: String, supports component: String) -> Bool {
        switch name {
        case "lineLimit", "multilineTextAlignment", "lineSpacing", "textSelection", "monospacedDigit":
            component == "Text"
        case "buttonStyle": component == "Button" || component == "Menu"
        case "font", "fontWeight", "fontDesign":
            ["Text", "Button", "Badge", "TextField", "SecureField"].contains(component)
        default: true
        }
    }
}

struct NativeUIClientFunctionIdentity: Hashable, Sendable {
    let name: String
    let revision: UInt64
}

enum NativeUIBundledDefinitions {
    static func load(_ definitionId: String, bundle: Bundle = .main) throws -> NativeUIDefinitionDTO {
        let candidate = bundle.url(
            forResource: definitionId,
            withExtension: "json",
            subdirectory: "native-ui-definitions"
        ) ?? bundle.url(forResource: definitionId, withExtension: "json")
        guard let url = candidate,
              let data = try? Data(contentsOf: url),
              let definition = try? JSONDecoder().decode(NativeUIDefinitionDTO.self, from: data)
        else {
            throw NativeUIProtocolError.invalidBundledDefinition(definitionId)
        }
        return definition
    }
}
