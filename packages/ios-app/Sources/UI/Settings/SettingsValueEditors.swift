import SwiftUI
import TronMobileCore

/// Secret drafts are always empty on entry. Only the replacement goes to the
/// mutation owner; the resolver's redacted display is never treated as a value.
struct SettingsSecretEditor: View {
    let title: String
    let help: String
    let onChange: (JSONValue?) -> Void
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SecureField("New value", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .tronField(monospaced: true, compact: true)
                    .accessibilityLabel("New value")
                    .tronSettingsCaption(help)
                TronSettingsGroup("Change value") {
                    TronSettingsRow(icon: "checkmark", title: "Replace value") {
                        Button { let value = draft; draft = ""; onChange(.string(value)); dismiss() } label: {
                            TronInlineActionLabel("Save")
                        }
                        .buttonStyle(.plain)
                        .disabled(draft.isEmpty)
                    }
                    TronSettingsDivider()
                    TronSettingsRow(icon: "arrow.uturn.backward", title: "Follow the default") {
                        Button { draft = ""; onChange(nil); dismiss() } label: { TronInlineActionLabel("Restore") }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .onDisappear { draft = "" }
    }
}

/// A schema-declared numeric map: field names, labels and bounds all come from
/// the Gateway. This editor knows no settings keys or thinking-level vocabulary.
struct SettingsNumberMapEditor: View {
    let title: String
    let help: String
    let fields: [SettingsChoice]
    let range: SettingsRange
    let onChange: (JSONValue?) -> Void
    @State private var drafts: [String: String]
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, help: String, fields: [SettingsChoice], range: SettingsRange,
         values: [String: JSONValue], onChange: @escaping (JSONValue?) -> Void) {
        self.title = title; self.help = help; self.fields = fields; self.range = range; self.onChange = onChange
        _drafts = State(initialValue: values.compactMapValues { value in
            guard case .number(let number) = value, let integer = Int(exactly: number) else { return nil }
            return String(integer)
        })
    }

    private var payload: JSONValue? {
        var values: [String: JSONValue] = [:]
        for field in fields {
            guard let key = field.value.stringValue else { return nil }
            let text = (drafts[key] ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard let number = Int(text), Double(number) >= range.min, Double(number) <= range.max,
                  (Double(number) - range.min).truncatingRemainder(dividingBy: range.step ?? 1) == 0 else { return nil }
            values[key] = .number(Double(number))
        }
        return .object(values)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TronSettingsGroup(title) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        if index > 0 { TronSettingsDivider() }
                        if let key = field.value.stringValue {
                            TronSettingsRow(icon: nil, title: field.label, subtitle: range.unit) {
                                TextField("Not set", text: Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 }))
                                    .keyboardType(.numbersAndPunctuation).submitLabel(.done)
                                    .focused($editing).onSubmit { editing = false }
                                    .tronInlineField(monospaced: true)
                                    .accessibilityLabel(field.label)
                            }
                        }
                    }
                }
                .tronSettingsCaption(help)
                if payload == nil {
                    TronSettingsNotice(message: "Enter whole numbers within the offered range.")
                }
                TronSettingsRow(icon: "checkmark", title: "Save values") {
                    Button {
                        guard let payload else { return }
                        editing = false
                        onChange(payload)
                        dismiss()
                    } label: { TronInlineActionLabel("Save") }
                    .buttonStyle(.plain).disabled(payload == nil)
                }
                .tronGlassSurface(accent: .tronEmerald)
            }.padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
    }
}

/// Ordered string values keep stable local row identity while editing. The
/// Gateway alone validates item syntax, count and allowed values on Save.
struct SettingsListEditor: View {
    private struct Item: Identifiable { let id = UUID(); var text: String }
    let title: String
    let help: String
    let onChange: (JSONValue?) -> Void
    @State private var items: [Item]
    @State private var next = ""
    @Environment(\.dismiss) private var dismiss

    init(title: String, help: String, values: [String], onChange: @escaping (JSONValue?) -> Void) {
        self.title = title; self.help = help; self.onChange = onChange
        _items = State(initialValue: values.map { Item(text: $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TronSettingsGroup(title) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { TronSettingsDivider() }
                        TronSettingsRow(icon: nil, title: item.text) {
                            TronInlineMenu("Edit") {
                                Button("Move up") { items.swapAt(index, index - 1) }.disabled(index == 0)
                                Button("Move down") { items.swapAt(index, index + 1) }.disabled(index + 1 == items.count)
                                Button("Remove", role: .destructive) { items.removeAll { $0.id == item.id } }
                            }
                            .accessibilityLabel("Edit \(item.text)")
                        }
                    }
                    if items.isEmpty { TronSettingsRow(icon: nil, title: "None") }
                }
                .tronSettingsCaption(help)
                TronSettingsRow(icon: "plus", title: "Add value") {
                    TextField("Value", text: $next)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .tronInlineField(monospaced: true)
                        .accessibilityLabel("Value")
                    Button { items.append(Item(text: next)); next = "" } label: { TronInlineActionLabel("Add") }
                        .buttonStyle(.plain).disabled(next.isEmpty)
                }
                .tronGlassSurface(accent: .tronEmerald)
                TronSettingsRow(icon: "checkmark", title: "Save list") {
                    Button { onChange(.array(items.map { .string($0.text) })); dismiss() } label: { TronInlineActionLabel("Save") }
                        .buttonStyle(.plain)
                }
                .tronGlassSurface(accent: .tronEmerald)
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
    }
}
