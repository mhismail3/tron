import SwiftUI

private struct JSONFieldSelection: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    let value: JSONValue
}

/// Progressive, bounded presentation for arbitrary Pi extension/tool JSON.
/// Known tool fields remain specialized; this is the intentional fallback for
/// unknown nested values rather than dumping a raw object into one text block.
struct TronStructuredJSONView: View {
    let value: JSONValue
    var title = "Result"
    var path = "$"
    var accent: Color = .tronPurple
    @State private var selectedField: JSONFieldSelection?
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.section) {
            switch value {
            case .object(let fields):
                fieldSection(fields.sorted { fieldRank($0.key) < fieldRank($1.key) }.map {
                    (label: humanized($0.key), component: $0.key, value: $0.value)
                })
            case .array(let values):
                fieldSection(values.enumerated().map {
                    (
                        label: arrayItemTitle($0.element, index: $0.offset),
                        component: String($0.offset),
                        value: $0.element
                    )
                })
            case .string(let text): primitive(text)
            case .number(let number): primitive(number.formatted())
            case .bool(let value): primitive(value ? "True" : "False")
            case .null: primitive("No value")
            }

            Button { showRaw.toggle() } label: {
                TronSettingsRow(
                    icon: "curlybraces",
                    title: showRaw ? "Hide raw JSON" : "View raw JSON",
                    subtitle: "Copyable protocol representation",
                    accent: .tronSlate
                ) {
                    Image(systemName: showRaw ? "chevron.up" : "chevron.down")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                }
            }
            .buttonStyle(.plain)
            .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08, interactive: true)

            if showRaw {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(value.prettyPrinted)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextSecondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08)
            }
        }
        .sheet(item: $selectedField) { selection in
            JSONFieldSheet(selection: selection, accent: accent)
        }
    }

    @ViewBuilder
    private func fieldSection(_ fields: [(label: String, component: String, value: JSONValue)]) -> some View {
        if fields.isEmpty {
            primitive("Empty collection")
        } else {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text("FIELDS")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
                TronGlassCard(accent: accent) {
                    VStack(spacing: 0) {
                        ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                            if index > 0 { TronSettingsDivider(accent: accent) }
                            Button {
                                selectedField = JSONFieldSelection(
                                    title: field.label,
                                    path: childPath(field.component),
                                    value: field.value
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

    private func arrayItemTitle(_ value: JSONValue, index: Int) -> String {
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
            return "\(provider) / \(id)"
        }
        return "Entry \(index + 1)"
    }

    private func childPath(_ component: String) -> String {
        path == "$" ? "$.\(component)" : "\(path).\(component)"
    }

    private func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func fieldRank(_ key: String) -> String {
        let preferred = ["status", "summary", "answer", "report", "result", "message", "warnings", "sources", "citations"]
        let rank = preferred.firstIndex(of: key) ?? preferred.count
        return String(format: "%02d-%@", rank, key.lowercased())
    }
}

private struct JSONFieldSheet: View {
    let selection: JSONFieldSelection
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.section) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SELECTED FIELD")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(Color.tronTextMuted)
                        Text(selection.path)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(Color.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                    TronStructuredJSONView(
                        value: selection.value,
                        title: selection.title,
                        path: selection.path,
                        accent: accent
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
