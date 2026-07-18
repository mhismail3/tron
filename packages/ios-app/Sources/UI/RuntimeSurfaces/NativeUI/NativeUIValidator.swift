import Foundation

enum NativeUIValidator {
    static func buildValidatedTree(
        messages: [NativeUIMessageDTO],
        encodedByteCount: Int? = nil
    ) throws -> NativeUISurfaceTree {
        var tree = NativeUISurfaceTree()
        var diagnostics: [NativeUIDiagnosticDTO] = []
        if let encodedByteCount, encodedByteCount > NativeUICatalog.maxPayloadBytes {
            diagnostics.append(.init(
                code: "definition.payload_too_large",
                path: "/",
                message: "Definition exceeds \(NativeUICatalog.maxPayloadBytes) bytes"
            ))
        }
        guard !messages.isEmpty else {
            throw NativeUIRuntimeError.invalidDefinition([.init(
                code: "a2ui.missing_messages", path: "/messages", message: "No A2UI messages"
            )])
        }
        for (index, message) in messages.enumerated() {
            do {
                try tree.apply(message)
            } catch {
                diagnostics.append(.init(
                    code: "a2ui.apply_failed",
                    path: "/messages/\(index)",
                    message: error.localizedDescription
                ))
            }
        }
        diagnostics.append(contentsOf: validate(tree))
        guard diagnostics.isEmpty else {
            throw NativeUIRuntimeError.invalidDefinition(diagnostics)
        }
        return tree
    }

    static func validate(_ tree: NativeUISurfaceTree) -> [NativeUIDiagnosticDTO] {
        var diagnostics: [NativeUIDiagnosticDTO] = []
        if tree.isDeleted {
            return diagnostics
        }
        if tree.catalogId != NativeUICatalog.id {
            diagnostics.append(.init(
                code: "catalog.unsupported", path: "/catalogId", message: "Unsupported native UI catalog"
            ))
        }
        if tree.components.count > NativeUICatalog.maxComponents {
            diagnostics.append(.init(
                code: "catalog.too_many_components",
                path: "/components",
                message: "Surface contains too many components"
            ))
        }
        guard tree.root != nil else {
            diagnostics.append(.init(
                code: "catalog.missing_root", path: "/components", message: "Surface requires root component"
            ))
            return diagnostics
        }

        var actionCount = 0
        for component in tree.components.values {
            let base = "/components/\(component.id)"
            guard NativeUICatalog.components.contains(component.component) else {
                diagnostics.append(.init(
                    code: "catalog.unknown_component", path: base, message: "Unknown component \(component.component)"
                ))
                continue
            }
            for property in component.properties.keys
            where !NativeUICatalog.allowedProperties(for: component.component).contains(property) {
                diagnostics.append(.init(
                    code: "catalog.unknown_property",
                    path: "\(base)/\(property)",
                    message: "Unknown property \(property) for \(component.component)"
                ))
            }
            validateRequiredProperties(component, at: base, diagnostics: &diagnostics)
            validateComponentValues(component, tree: tree, at: base, diagnostics: &diagnostics)
            validateModifiers(component, at: base, diagnostics: &diagnostics)
            if let action = component.properties["action"] {
                actionCount += validateAction(action, at: "\(base)/action", diagnostics: &diagnostics)
            }
        }
        if actionCount > NativeUICatalog.maxActions {
            diagnostics.append(.init(
                code: "action.too_many", path: "/components", message: "Surface contains too many actions"
            ))
        }

        var visiting: Set<String> = []
        var visited: Set<String> = []
        walk(
            "root", depth: 0, tree: tree, visiting: &visiting,
            visited: &visited, diagnostics: &diagnostics
        )
        return diagnostics
    }

    private static func validateComponentValues(
        _ component: NativeUIComponentDTO,
        tree: NativeUISurfaceTree,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        validateProperty(component, "visible", tree: tree, at: path, allowsBinding: true,
                         expected: "a boolean", diagnostics: &diagnostics) { $0.boolValue != nil }
        validateProperty(component, "accessibilityLabel", tree: tree, at: path, allowsBinding: true,
                         expected: "a string", diagnostics: &diagnostics) { $0.stringValue != nil }

        let stringProperties: [String]
        let numericProperties: [String]
        let booleanProperties: [String]
        switch component.component {
        case "Surface":
            stringProperties = ["child"]; numericProperties = []; booleanProperties = []
        case "Navigation":
            stringProperties = ["child", "title"]; numericProperties = []; booleanProperties = []
        case "Scroll":
            stringProperties = ["child", "axis"]; numericProperties = []; booleanProperties = ["showsIndicators"]
        case "Row", "Column", "Overlay":
            stringProperties = ["alignment"]; numericProperties = ["spacing"]; booleanProperties = []
        case "Grid":
            stringProperties = []; numericProperties = ["columns", "spacing"]; booleanProperties = []
        case "AdaptiveColumns":
            stringProperties = []; numericProperties = ["minimumColumnWidth", "spacing"]; booleanProperties = []
        case "List":
            stringProperties = []; numericProperties = ["spacing"]; booleanProperties = []
        case "Section":
            stringProperties = ["title", "icon", "footer"]; numericProperties = []; booleanProperties = []
        case "GlassCard":
            stringProperties = ["accent"]; numericProperties = []; booleanProperties = ["interactive"]
        case "Divider":
            stringProperties = ["orientation"]; numericProperties = []; booleanProperties = []
        case "Spacer":
            stringProperties = []; numericProperties = ["minimumLength"]; booleanProperties = []
        case "Text":
            stringProperties = ["text", "label", "icon", "style", "format"]
            numericProperties = []; booleanProperties = ["selectable"]
        case "Image":
            stringProperties = ["name", "url", "contentMode"]; numericProperties = []; booleanProperties = []
        case "Icon":
            stringProperties = ["systemName", "tone"]; numericProperties = ["size"]; booleanProperties = []
        case "Badge":
            stringProperties = ["text", "tone"]; numericProperties = []; booleanProperties = []
        case "Progress":
            stringProperties = ["label"]; numericProperties = ["value", "total"]; booleanProperties = []
        case "EmptyState":
            stringProperties = ["title", "message", "systemImage"]; numericProperties = []; booleanProperties = []
        case "Button":
            stringProperties = ["label", "value", "icon", "role"]; numericProperties = []; booleanProperties = []
        case "Toggle":
            stringProperties = ["label", "icon"]; numericProperties = []; booleanProperties = []
        case "Slider", "Stepper":
            stringProperties = ["label", "icon", "format", "commit"]
            numericProperties = ["value", "minimum", "maximum", "step"]; booleanProperties = []
        case "TextField", "SecureField":
            stringProperties = ["label", "value", "placeholder"]; numericProperties = []; booleanProperties = []
        case "ChoicePicker":
            stringProperties = ["label", "value"]; numericProperties = []; booleanProperties = []
        case "Menu":
            stringProperties = ["label", "icon"]; numericProperties = []; booleanProperties = []
        case "ResourcePicker":
            stringProperties = ["label", "kind", "selected"]; numericProperties = []; booleanProperties = []
        case "NativeSlot":
            stringProperties = ["name"]; numericProperties = []; booleanProperties = []
        default:
            return
        }

        for key in stringProperties {
            validateProperty(component, key, tree: tree, at: path, allowsBinding: true,
                             expected: "a string", diagnostics: &diagnostics) { $0.stringValue != nil }
        }
        for key in numericProperties {
            validateProperty(component, key, tree: tree, at: path, allowsBinding: key == "value",
                             expected: "a finite number", diagnostics: &diagnostics) {
                $0.numberValue.map(\.isFinite) == true
            }
        }
        for key in booleanProperties {
            validateProperty(component, key, tree: tree, at: path, allowsBinding: false,
                             expected: "a boolean", diagnostics: &diagnostics) { $0.boolValue != nil }
        }

        if ["Row", "Column", "Overlay", "Grid", "AdaptiveColumns", "List", "Section", "GlassCard", "Menu"]
            .contains(component.component) {
            validateProperty(component, "children", tree: tree, at: path, allowsBinding: false,
                             expected: "an array of component ids", diagnostics: &diagnostics) { value in
                value.arrayValue.map { !$0.isEmpty && $0.allSatisfy { $0.stringValue?.isEmpty == false } } == true
            }
        }
        if component.component == "Toggle" {
            validateProperty(component, "value", tree: tree, at: path, allowsBinding: true,
                             expected: "a boolean binding", diagnostics: &diagnostics) { $0.boolValue != nil }
        }
        validateComponentEnumsAndBounds(component, at: path, diagnostics: &diagnostics)

        if component.component == "ChoicePicker", let options = component.properties["options"] {
            guard let values = options.arrayValue, !values.isEmpty, values.count <= 100,
                  values.allSatisfy({ option in
                      guard let object = option.objectValue else { return false }
                      return Set(object.keys) == ["label", "value"]
                          && object["label"]?.stringValue?.isEmpty == false
                          && object["value"]?.stringValue?.isEmpty == false
                  })
            else {
                diagnostics.append(.init(
                    code: "catalog.invalid_options", path: "\(path)/options",
                    message: "ChoicePicker options require 1-100 exact label/value objects"
                ))
                return
            }
        }
        if component.component == "NativeSlot" {
            if component.properties["name"]?.stringValue != "surfaceDiagnostics" {
                diagnostics.append(.init(
                    code: "catalog.unsupported_native_slot", path: "\(path)/name",
                    message: "NativeSlot is limited to the cataloged surfaceDiagnostics slot"
                ))
            }
            if component.properties["arguments"]?.objectValue == nil {
                diagnostics.append(.init(
                    code: "catalog.invalid_native_slot_arguments", path: "\(path)/arguments",
                    message: "NativeSlot arguments must be an object"
                ))
            }
        }
    }

    private static func validateProperty(
        _ component: NativeUIComponentDTO,
        _ key: String,
        tree: NativeUISurfaceTree,
        at path: String,
        allowsBinding: Bool,
        expected: String,
        diagnostics: inout [NativeUIDiagnosticDTO],
        predicate: (NativeUIJSONValue) -> Bool
    ) {
        guard let value = component.properties[key] else { return }
        if case .object(let object) = value, object["path"] != nil {
            guard allowsBinding, object.count == 1,
                  let pointer = object["path"]?.stringValue,
                  pointer.first == "/"
            else {
                diagnostics.append(.init(
                    code: "binding.invalid", path: "\(path)/\(key)",
                    message: "Binding must be an exact non-empty JSON Pointer object"
                ))
                return
            }
            if let resolved = tree.value(at: pointer), !predicate(resolved) {
                diagnostics.append(.init(
                    code: "binding.type_mismatch", path: "\(path)/\(key)",
                    message: "Resolved binding must be \(expected)"
                ))
            }
            return
        }
        if !predicate(value) {
            diagnostics.append(.init(
                code: "catalog.invalid_property_type", path: "\(path)/\(key)",
                message: "Property \(key) must be \(expected)"
            ))
        }
    }

    private static func validateComponentEnumsAndBounds(
        _ component: NativeUIComponentDTO,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        func requireEnum(_ key: String, _ allowed: Set<String>) {
            guard let raw = component.properties[key], raw.objectValue == nil,
                  let value = raw.stringValue, !allowed.contains(value)
            else { return }
            diagnostics.append(.init(
                code: "catalog.invalid_enum", path: "\(path)/\(key)",
                message: "Unsupported \(key) value \(value)"
            ))
        }
        requireEnum("axis", ["vertical", "horizontal"])
        requireEnum("orientation", ["horizontal", "vertical"])
        requireEnum("contentMode", ["fit", "fill"])
        requireEnum("role", ["normal", "secondary", "cancel", "destructive"])
        requireEnum("format", ["number", "percent"])
        requireEnum("commit", ["change", "interactionEnd", "submit"])
        requireEnum("kind", ["workspace", "model"])
        if let columns = component.properties["columns"]?.numberValue,
           columns.rounded() != columns || !(1...8).contains(columns) {
            diagnostics.append(.init(
                code: "catalog.invalid_columns", path: "\(path)/columns",
                message: "Grid columns must be an integer from 1 through 8"
            ))
        }
        for key in ["spacing", "minimumLength", "size", "minimumColumnWidth"] {
            if let number = component.properties[key]?.numberValue,
               number < 0 || number > 10_000 {
                diagnostics.append(.init(
                    code: "catalog.numeric_out_of_bounds", path: "\(path)/\(key)",
                    message: "Numeric property is outside its bounded range"
                ))
            }
        }
        if let step = component.properties["step"]?.numberValue, step <= 0 {
            diagnostics.append(.init(
                code: "catalog.invalid_step", path: "\(path)/step", message: "Step must be positive"
            ))
        }
        if let minimum = component.properties["minimum"]?.numberValue,
           let maximum = component.properties["maximum"]?.numberValue,
           minimum > maximum {
            diagnostics.append(.init(
                code: "catalog.invalid_range", path: path, message: "Minimum cannot exceed maximum"
            ))
        }
    }

    private static func validateRequiredProperties(
        _ component: NativeUIComponentDTO,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        let required: [String] = switch component.component {
        case "Surface", "Navigation", "Scroll": ["child"]
        case "Row", "Column", "Overlay", "Grid", "AdaptiveColumns", "List", "Section", "GlassCard", "Menu": ["children"]
        case "Text": ["text"]
        case "Image": ["name"]
        case "Icon": ["systemName"]
        case "Badge": ["text"]
        case "EmptyState": ["title"]
        case "Button": ["label", "action"]
        case "Toggle", "Slider", "Stepper", "TextField", "SecureField": ["label", "value", "action"]
        case "ChoicePicker": ["label", "value", "options", "action"]
        case "ResourcePicker": ["label", "kind", "action"]
        case "NativeSlot": ["name", "arguments"]
        default: []
        }
        for name in required where component.properties[name] == nil {
            diagnostics.append(.init(
                code: "catalog.missing_property",
                path: path,
                message: "\(component.component) requires \(name)"
            ))
        }
    }

    private static func validateModifiers(
        _ component: NativeUIComponentDTO,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        guard let raw = component.properties["modifiers"] else { return }
        guard case .array(let modifiers) = raw,
              modifiers.count <= NativeUICatalog.maxModifiersPerComponent
        else {
            diagnostics.append(.init(
                code: "modifier.invalid_array", path: "\(path)/modifiers", message: "Invalid modifier array"
            ))
            return
        }
        for (index, modifier) in modifiers.enumerated() {
            guard case .object(let object) = modifier,
                  let name = object["name"]?.stringValue,
                  NativeUICatalog.modifiers.contains(name),
                  NativeUICatalog.modifier(name, supports: component.component)
            else {
                diagnostics.append(.init(
                    code: "modifier.invalid",
                    path: "\(path)/modifiers/\(index)",
                    message: "Unknown or inapplicable modifier"
                ))
                continue
            }
            let allowedKeys = modifierKeys(name)
            for key in object.keys where !allowedKeys.contains(key) {
                diagnostics.append(.init(
                    code: "modifier.unknown_property",
                    path: "\(path)/modifiers/\(index)/\(key)",
                    message: "Property \(key) is not valid for modifier \(name)"
                ))
            }
            for number in object.values.compactMap(\.numberValue)
            where !number.isFinite || !(-10_000...10_000).contains(number) {
                diagnostics.append(.init(
                    code: "modifier.value_out_of_bounds",
                    path: "\(path)/modifiers/\(index)",
                    message: "Modifier numeric value is outside allowed bounds"
                ))
            }
            for key in colorKeys(for: name) {
                if let value = object[key] {
                    validateColor(value, at: "\(path)/modifiers/\(index)/\(key)", diagnostics: &diagnostics)
                }
            }
            if name == "sizeClass" {
                for key in ["compact", "regular"] where object[key] != nil {
                    validateSizeClassOverride(
                        object[key]!,
                        at: "\(path)/modifiers/\(index)/\(key)",
                        diagnostics: &diagnostics
                    )
                }
            }
            validateModifierValueTypes(
                name,
                object: object,
                at: "\(path)/modifiers/\(index)",
                diagnostics: &diagnostics
            )
        }
    }

    private static func modifierKeys(_ name: String) -> Set<String> {
        switch name {
        case "frame": ["name", "width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "alignment"]
        case "padding": ["name", "edges", "value"]
        case "offset": ["name", "x", "y"]
        case "fixedSize": ["name", "horizontal", "vertical"]
        case "aspectRatio": ["name", "value", "contentMode"]
        case "font": ["name", "style", "size"]
        case "fontWeight", "fontDesign", "foregroundStyle", "tint", "background", "clipShape", "contentShape", "buttonStyle", "transition": ["name", "value"]
        case "opacity", "cornerRadius", "lineSpacing": ["name", "value"]
        case "glassEffect": ["name", "style", "tint", "interactive"]
        case "shadow": ["name", "color", "radius", "x", "y"]
        case "overlay", "stroke": ["name", "color", "width"]
        case "lineLimit": ["name", "value", "reservesSpace"]
        case "multilineTextAlignment": ["name", "value"]
        case "textSelection", "monospacedDigit", "hidden": ["name", "enabled"]
        case "disabled": ["name", "value"]
        case "accessibility": ["name", "label", "hint", "value", "identifier"]
        case "animation": ["name", "preset", "duration", "valuePath"]
        case "sizeClass": ["name", "compact", "regular"]
        default: ["name"]
        }
    }

    private static func validateModifierValueTypes(
        _ name: String,
        object: [String: NativeUIJSONValue],
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        let numericKeys: [String] = switch name {
        case "frame": ["width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight"]
        case "padding": ["value"]
        case "offset": ["x", "y"]
        case "aspectRatio": ["value"]
        case "font": ["size"]
        case "opacity", "cornerRadius", "lineSpacing": ["value"]
        case "shadow": ["radius", "x", "y"]
        case "overlay", "stroke": ["width"]
        case "lineLimit": ["value"]
        case "animation": ["duration"]
        default: []
        }
        for key in numericKeys where object[key] != nil {
            if name == "frame", ["maxWidth", "maxHeight"].contains(key),
               object[key]?.stringValue == "infinity" {
                continue
            }
            guard let number = object[key]?.numberValue, number.isFinite else {
                diagnostics.append(.init(
                    code: "modifier.invalid_number", path: "\(path)/\(key)",
                    message: "Modifier property \(key) must be a finite number"
                ))
                continue
            }
            let requiresNonnegative = !["offset", "lineSpacing"].contains(name)
                && !(name == "shadow" && ["x", "y"].contains(key))
            if requiresNonnegative && number < 0 {
                diagnostics.append(.init(
                    code: "modifier.negative_value", path: "\(path)/\(key)",
                    message: "Modifier property \(key) cannot be negative"
                ))
            }
            if name == "opacity" && !(0...1).contains(number) {
                diagnostics.append(.init(
                    code: "modifier.invalid_opacity", path: "\(path)/value",
                    message: "Opacity must be between zero and one"
                ))
            }
            if name == "lineLimit" && (number.rounded() != number || !(1...100).contains(number)) {
                diagnostics.append(.init(
                    code: "modifier.invalid_line_limit", path: "\(path)/value",
                    message: "Line limit must be an integer from 1 through 100"
                ))
            }
            if name == "animation" && number > 10 {
                diagnostics.append(.init(
                    code: "modifier.invalid_animation_duration", path: "\(path)/duration",
                    message: "Animation duration cannot exceed ten seconds"
                ))
            }
        }
        let booleanKeys: [String] = switch name {
        case "fixedSize": ["horizontal", "vertical"]
        case "glassEffect": ["interactive"]
        case "lineLimit": ["reservesSpace"]
        case "textSelection", "monospacedDigit", "hidden": ["enabled"]
        case "disabled": ["value"]
        default: []
        }
        for key in booleanKeys where object[key] != nil && object[key]?.boolValue == nil {
            diagnostics.append(.init(
                code: "modifier.invalid_boolean", path: "\(path)/\(key)",
                message: "Modifier property \(key) must be a boolean"
            ))
        }
        let enums: [String: Set<String>] = switch name {
        case "padding": ["edges": ["all", "horizontal", "vertical", "top", "bottom", "leading", "trailing"]]
        case "aspectRatio": ["contentMode": ["fit", "fill"]]
        case "fontWeight": ["value": ["regular", "medium", "semibold", "bold", "light"]]
        case "fontDesign": ["value": ["default", "rounded", "monospaced", "serif"]]
        case "multilineTextAlignment": ["value": ["leading", "center", "trailing"]]
        case "buttonStyle": ["value": ["plain", "bordered", "prominent"]]
        case "transition": ["value": ["opacity", "scale", "opacityScale"]]
        case "animation": ["preset": ["easeIn", "easeOut", "easeInOut", "spring"]]
        default: [:]
        }
        for (key, allowed) in enums where object[key] != nil {
            guard let value = object[key]?.stringValue, allowed.contains(value) else {
                diagnostics.append(.init(
                    code: "modifier.invalid_enum", path: "\(path)/\(key)",
                    message: "Modifier property \(key) has an unsupported value"
                ))
                continue
            }
        }
        if let pointer = object["valuePath"],
           pointer.stringValue?.first != "/" {
            diagnostics.append(.init(
                code: "modifier.invalid_value_path", path: "\(path)/valuePath",
                message: "Animation valuePath must be a JSON Pointer"
            ))
        }
    }

    private static func colorKeys(for modifier: String) -> [String] {
        switch modifier {
        case "foregroundStyle", "tint", "background": ["value"]
        case "glassEffect": ["tint"]
        case "shadow", "overlay", "stroke": ["color"]
        default: []
        }
    }

    private static func validateColor(
        _ value: NativeUIJSONValue,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        if let token = value.stringValue {
            let allowed: Set<String> = [
                "accent", "emerald", "purple", "cyan", "mint", "red", "destructive",
                "secondary", "muted", "surface", "surfaceElevated", "border", "primary",
                "success", "warning",
            ]
            if !allowed.contains(token) {
                diagnostics.append(.init(
                    code: "modifier.unknown_color_token", path: path,
                    message: "Color token is not part of catalog revision 1"
                ))
            }
            return
        }
        guard let object = value.objectValue,
              object.keys.allSatisfy({ ["red", "green", "blue", "alpha"].contains($0) }),
              ["red", "green", "blue"].allSatisfy({ object[$0] != nil }),
              object.values.allSatisfy({
                  $0.numberValue.map { $0.isFinite && (0...1).contains($0) } == true
              })
        else {
            diagnostics.append(.init(
                code: "modifier.invalid_color",
                path: path,
                message: "Color must be a token or bounded RGBA object"
            ))
            return
        }
    }

    private static func validateSizeClassOverride(
        _ value: NativeUIJSONValue,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        guard let object = value.objectValue,
              object.keys.allSatisfy({ ["padding", "maxWidth", "hidden"].contains($0) }),
              ["padding", "maxWidth"].allSatisfy({ key in
                  guard let value = object[key] else { return true }
                  return value.numberValue.map { $0.isFinite && (0...10_000).contains($0) } == true
              }),
              object["hidden"].map({ $0.boolValue != nil }) ?? true
        else {
            diagnostics.append(.init(
                code: "modifier.invalid_size_class",
                path: path,
                message: "Invalid compact/regular override"
            ))
            return
        }
    }

    private static func validateAction(
        _ action: NativeUIJSONValue,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) -> Int {
        guard case .object(let object) = action else {
            diagnostics.append(.init(code: "action.invalid", path: path, message: "Action must be an object"))
            return 1
        }
        let allowed = Set(["serverCapability", "clientFunction", "event", "resultAction"])
        for key in object.keys where !allowed.contains(key) {
            diagnostics.append(.init(
                code: "action.unknown_property", path: "\(path)/\(key)",
                message: "Unknown action property \(key)"
            ))
        }
        let variants = ["serverCapability", "clientFunction", "event"].filter { object[$0] != nil }
        if variants.count != 1 {
            diagnostics.append(.init(
                code: "action.invalid_variant", path: path, message: "Action requires exactly one action variant"
            ))
        }
        if let raw = object["serverCapability"] {
            guard let binding = raw.objectValue,
                  Set(binding.keys) == ["functionId", "argumentTemplate"],
                  binding["functionId"]?.stringValue?.isEmpty == false,
                  let template = binding["argumentTemplate"]?.objectValue
            else {
                diagnostics.append(.init(
                    code: "action.invalid_capability", path: "\(path)/serverCapability",
                    message: "Server capability requires exact functionId and argumentTemplate fields"
                ))
                return 1
            }
            validateTemplate(.object(template), at: "\(path)/serverCapability/argumentTemplate", diagnostics: &diagnostics)
        }
        if let raw = object["clientFunction"] {
            guard let function = raw.objectValue,
                  Set(function.keys) == ["name", "revision", "arguments"],
                  let name = function["name"]?.stringValue,
                  !name.isEmpty,
                  let number = function["revision"]?.numberValue,
                  number.isFinite,
                  number >= 0,
                  number.rounded() == number,
                  let revision = UInt64(exactly: number),
                  let arguments = function["arguments"]?.objectValue
            else {
                diagnostics.append(.init(
                    code: "action.invalid_client_function", path: "\(path)/clientFunction",
                    message: "Client function requires exact name, integer revision, and arguments fields"
                ))
                return 1
            }
            let identity = NativeUIClientFunctionIdentity(name: name, revision: revision)
            if !NativeUICatalog.clientFunctions.contains(identity) {
                diagnostics.append(.init(
                    code: "action.unsupported_client_function", path: path, message: "Unsupported native function"
                ))
            }
            validateTemplate(.object(arguments), at: "\(path)/clientFunction/arguments", diagnostics: &diagnostics)
        }
        if let raw = object["event"] {
            guard let event = raw.objectValue,
                  event.keys.allSatisfy({ ["name", "context"].contains($0) }),
                  event["name"]?.stringValue?.isEmpty == false
            else {
                diagnostics.append(.init(
                    code: "action.invalid_event", path: "\(path)/event",
                    message: "Event action requires a non-empty name and optional context"
                ))
                return 1
            }
            if let context = event["context"] {
                validateTemplate(context, at: "\(path)/event/context", diagnostics: &diagnostics)
            }
        }
        if let result = object["resultAction"] {
            return 1 + validateAction(result, at: "\(path)/resultAction", diagnostics: &diagnostics)
        }
        return 1
    }

    private static func validateTemplate(
        _ value: NativeUIJSONValue,
        at path: String,
        diagnostics: inout [NativeUIDiagnosticDTO],
        depth: Int = 0
    ) {
        guard depth <= NativeUICatalog.maxDepth else {
            diagnostics.append(.init(
                code: "binding.depth_exceeded", path: path, message: "Binding template is too deeply nested"
            ))
            return
        }
        switch value {
        case .array(let values):
            for (index, child) in values.enumerated() {
                validateTemplate(child, at: "\(path)/\(index)", diagnostics: &diagnostics, depth: depth + 1)
            }
        case .object(let object):
            let reserved = Set(object.keys).intersection(["path", "$event", "$result"])
            if !reserved.isEmpty {
                guard object.count == 1, reserved.count == 1,
                      let key = reserved.first,
                      let token = object[key]?.stringValue,
                      !token.isEmpty,
                      key != "path" || token.first == "/"
                else {
                    diagnostics.append(.init(
                        code: "binding.invalid_expression", path: path,
                        message: "Binding expressions must contain exactly one valid path, $event, or $result token"
                    ))
                    return
                }
            } else {
                for (key, child) in object {
                    validateTemplate(child, at: "\(path)/\(key)", diagnostics: &diagnostics, depth: depth + 1)
                }
            }
        default:
            break
        }
    }

    private static func walk(
        _ id: String,
        depth: Int,
        tree: NativeUISurfaceTree,
        visiting: inout Set<String>,
        visited: inout Set<String>,
        diagnostics: inout [NativeUIDiagnosticDTO]
    ) {
        if depth > NativeUICatalog.maxDepth {
            diagnostics.append(.init(
                code: "catalog.depth_exceeded", path: "/components/\(id)", message: "Component depth exceeds limit"
            ))
            return
        }
        if visiting.contains(id) {
            diagnostics.append(.init(
                code: "catalog.cycle", path: "/components/\(id)", message: "Component graph contains a cycle"
            ))
            return
        }
        if visited.contains(id) { return }
        guard let component = tree.components[id] else {
            diagnostics.append(.init(
                code: "catalog.missing_child", path: "/components/\(id)", message: "Referenced component is missing"
            ))
            return
        }
        visiting.insert(id)
        for child in children(of: component) {
            walk(
                child, depth: depth + 1, tree: tree, visiting: &visiting,
                visited: &visited, diagnostics: &diagnostics
            )
        }
        visiting.remove(id)
        visited.insert(id)
    }

    static func children(of component: NativeUIComponentDTO) -> [String] {
        var children: [String] = []
        if let child = component.properties["child"]?.stringValue { children.append(child) }
        if case .array(let values) = component.properties["children"] {
            children.append(contentsOf: values.compactMap(\.stringValue))
        }
        return children
    }
}
