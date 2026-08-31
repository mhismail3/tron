import Foundation
import SwiftUI

enum StructuredJSONPathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)
}

enum StructuredJSONPath {
    static func resolve(_ root: JSONValue, components: [StructuredJSONPathComponent]) -> JSONValue? {
        components.reduce(Optional(root)) { value, component in
            guard let value else { return nil }
            switch component {
            case .key(let key): return value.objectValue?[key]
            case .index(let index):
                guard let values = value.arrayValue, values.indices.contains(index) else { return nil }
                return values[index]
            }
        }
    }

    static func display(_ components: [StructuredJSONPathComponent]) -> String {
        components.reduce("$") { path, component in
            switch component {
            case .key(let key) where isIdentifier(key): "\(path).\(key)"
            case .key(let key): "\(path)[\"\(escapedKey(key))\"]"
            case .index(let index): "\(path)[\(index)]"
            }
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func escapedKey(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x08: "\\b"
            case 0x09: "\\t"
            case 0x0A: "\\n"
            case 0x0C: "\\f"
            case 0x0D: "\\r"
            case 0x22: "\\\""
            case 0x5C: "\\\\"
            case 0x00 ... 0x1F: String(format: "\\u%04X", scalar.value)
            default: String(scalar)
            }
        }.joined()
    }
}

struct StructuredJSONField: Identifiable, Sendable {
    let position: Int
    let component: StructuredJSONPathComponent
    let value: JSONValue

    var id: StructuredJSONPathComponent { component }

    var label: String {
        switch component {
        case .key(let key): Self.humanized(key)
        case .index(let index): Self.arrayItemTitle(value, index: index)
        }
    }

    private static func arrayItemTitle(_ value: JSONValue, index: Int) -> String {
        if let text = value.stringValue, !text.isEmpty {
            return URL(fileURLWithPath: text).lastPathComponent.ifEmpty(text)
        }
        guard let object = value.objectValue else { return "Entry \(index + 1)" }
        for key in ["name", "title", "displayName", "label", "id", "source", "path", "filePath", "command"] {
            guard let text = object[key]?.stringValue, !text.isEmpty else { continue }
            return ["path", "filePath"].contains(key)
                ? URL(fileURLWithPath: text).lastPathComponent.ifEmpty(text)
                : text
        }
        if let provider = object["provider"]?.stringValue,
           let id = object["modelId"]?.stringValue ?? object["id"]?.stringValue {
            return ModelDisplayFormatting.reference(provider: provider, model: id)
        }
        return "Entry \(index + 1)"
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

struct StructuredJSONFields: RandomAccessCollection, Sendable {
    typealias Index = Int

    private enum Storage: Sendable {
        case object(values: [String: JSONValue], keys: [String])
        case array([JSONValue])
    }

    private let storage: Storage
    let startIndex = 0
    let endIndex: Int

    init(object: [String: JSONValue]) {
        let keys = object.keys.sorted { Self.fieldRank($0) < Self.fieldRank($1) }
        storage = .object(values: object, keys: keys)
        endIndex = keys.count
    }

    init(array: [JSONValue]) {
        storage = .array(array)
        endIndex = array.count
    }

    subscript(position: Int) -> StructuredJSONField {
        precondition(indices.contains(position))
        switch storage {
        case .object(let values, let keys):
            let key = keys[position]
            return StructuredJSONField(
                position: position,
                component: .key(key),
                value: values[key]!
            )
        case .array(let values):
            let value = values[position]
            return StructuredJSONField(
                position: position,
                component: .index(position),
                value: value
            )
        }
    }

    private static func fieldRank(_ key: String) -> String {
        let preferred = ["status", "summary", "answer", "report", "result", "message", "warnings", "sources", "citations"]
        let rank = preferred.firstIndex(of: key) ?? preferred.count
        return String(format: "%02d-%@", rank, key.lowercased())
    }
}

private struct JSONFieldSelection: Identifiable {
    let title: String
    let components: [StructuredJSONPathComponent]

    var id: [StructuredJSONPathComponent] { components }
    var path: String { StructuredJSONPath.display(components) }
}

/// Progressive, bounded presentation for arbitrary Pi extension/tool JSON.
/// Known tool fields remain specialized; this is the intentional fallback for
/// unknown nested values rather than dumping a raw object into one text block.
struct TronStructuredJSONView: View {
    let value: JSONValue
    var title = "Result"
    var path = "$"
    var accent: Color = .tronPurple
    var showsRawDisclosure = true
    var rootValue: JSONValue? = nil
    var pathComponents: [StructuredJSONPathComponent] = []
    @State private var selectedField: JSONFieldSelection?

    private var authoritativeRoot: JSONValue { rootValue ?? value }

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.section) {
            switch value {
            case .object(let fields):
                fieldSection(StructuredJSONFields(object: fields))
            case .array(let values):
                fieldSection(StructuredJSONFields(array: values))
            case .string(let text): primitive(text)
            case .number(let number): primitive(number.formatted())
            case .bool(let value): primitive(value ? "True" : "False")
            case .null: primitive("No value")
            }

            if showsRawDisclosure {
                TronTechnicalJSONRow(value: value)
            }
        }
        .tronManagedSheet(
            item: $selectedField,
            identity: { _ in "structured-json.field" }
        ) { selection in
            JSONFieldSheet(
                selection: selection,
                rootValue: authoritativeRoot,
                accent: accent,
                showsRawDisclosure: showsRawDisclosure
            )
        }
    }

    @ViewBuilder
    private func fieldSection(_ fields: StructuredJSONFields) -> some View {
        if fields.isEmpty {
            primitive("Empty collection")
        } else {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text("FIELDS")
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextMuted)
                TronGlassCard(accent: accent) {
                    LazyVStack(spacing: 0) {
                        ForEach(fields) { field in
                            if field.position > 0 { TronSettingsDivider(accent: accent) }
                            Button {
                                selectedField = JSONFieldSelection(
                                    title: field.label,
                                    components: pathComponents + [field.component]
                                )
                            } label: {
                                HStack(alignment: .center, spacing: 11) {
                                    Image(systemName: field.value.isCollection ? "doc.text.magnifyingglass" : "text.alignleft")
                                        .foregroundStyle(accent)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(field.label)
                                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                                .foregroundStyle(Color.tronTextPrimary)
                                            Spacer()
                                            Text(field.value.typeName)
                                                .font(TronTypography.caption)
                                                .foregroundStyle(Color.tronTextMuted)
                                        }
                                        Text(field.value.preview)
                                            .font(TronTypography.caption)
                                            .foregroundStyle(Color.tronTextSecondary)
                                            .lineLimit(3)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func primitive(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.bodySM)
            .foregroundStyle(Color.tronTextPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronGlassSurface(accent: accent, tintOpacity: 0.10)
    }

}

/// Shared raw protocol evidence affordance. Raw JSON never expands inline: the
/// row owns one selectable, scrollable sheet that begins at the medium detent.
struct TronTechnicalJSONRow: View {
    let value: JSONValue
    var title = "Technical JSON"
    var subtitle = "View full protocol representation"
    var sheetTitle = "Technical JSON"
    var accent: Color = .tronSlate
    var onEdit: (() -> Void)?
    @State private var isPresented = false
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        Button {
            detent = .medium
            isPresented = true
        } label: {
            TronSettingsRow(
                icon: "curlybraces",
                title: title,
                subtitle: subtitle,
                accent: accent
            )
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: accent, tintOpacity: 0.08, interactive: true)
        .accessibilityIdentifier("technical-json-row")
        .accessibilityHint("Opens scrollable JSON details")
        .tronManagedSheet(
            isPresented: $isPresented,
            identity: "structured-json.technical"
        ) {
            TechnicalJSONSheet(
                value: value,
                title: sheetTitle,
                accent: accent,
                detent: $detent,
                onEdit: onEdit
            )
        }
    }
}

private struct TechnicalJSONSheet: View {
    let value: JSONValue
    let title: String
    let accent: Color
    @Binding var detent: PresentationDetent
    let onEdit: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var document: String?

    var body: some View {
        NavigationStack {
            ZStack {
                TronReadOnlyTextView(text: document ?? "", style: .code)
                    .tronTopBlurSurface()
                if document == nil {
                    TronLoadingState(label: "Preparing JSON…", accent: accent)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: title, accent: accent)
                }
                if let onEdit {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                            onEdit()
                        } label: {
                            TronToolbarTextLabel("Edit", systemImage: "pencil")
                        }
                        .tronToolbarAction(accent: .tronEmerald)
                    }
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
        }
        .task(id: value) {
            document = nil
            let source = value
            let worker = Task.detached(priority: .userInitiated) { () -> String in
                guard !Task.isCancelled else { return "" }
                let rendered = source.prettyPrinted
                return Task.isCancelled ? "" : rendered
            }
            let rendered = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            document = rendered
        }
        .accessibilityIdentifier("technical-json-sheet")
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
    }
}

private struct JSONFieldSheet: View {
    let selection: JSONFieldSelection
    let rootValue: JSONValue
    let accent: Color
    let showsRawDisclosure: Bool
    @Environment(\.dismiss) private var dismiss

    private var selectedValue: JSONValue {
        StructuredJSONPath.resolve(rootValue, components: selection.components) ?? .null
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.section) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SELECTED FIELD")
                            .font(TronTypography.sheetSectionHeader)
                            .foregroundStyle(Color.tronTextMuted)
                        Text(selection.path)
                            .font(TronTypography.codeJSON)
                            .foregroundStyle(Color.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                    TronStructuredJSONView(
                        value: selectedValue,
                        title: selection.title,
                        path: selection.path,
                        accent: accent,
                        showsRawDisclosure: showsRawDisclosure,
                        rootValue: rootValue,
                        pathComponents: selection.components
                    )
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: selection.title, accent: accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
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
        .tint(Color.tronEmerald)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private extension JSONValue {
    var isCollection: Bool {
        switch self { case .object, .array: true; default: false }
    }

    var typeName: String {
        switch self {
        case .object(let value): "Object · \(value.count) field\(value.count == 1 ? "" : "s")"
        case .array(let value): "List · \(value.count) item\(value.count == 1 ? "" : "s")"
        case .string: "Text"
        case .number: "Number"
        case .bool: "Boolean"
        case .null: "Empty"
        }
    }

    var preview: String {
        switch self {
        case .object(let value): "\(value.count) field\(value.count == 1 ? "" : "s")"
        case .array(let value): "\(value.count) item\(value.count == 1 ? "" : "s")"
        case .string(let value): String(value.replacingOccurrences(of: "\n", with: " ").prefix(180))
        case .number(let value): value.formatted()
        case .bool(let value): value ? "True" : "False"
        case .null: "No value"
        }
    }
}
