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
                    .tronTextEntryDone()
                    .accessibilityLabel("New value")
                    .tronSettingsCaption(help)
                TronGlassCard(accent: .tronEmerald) {
                    Button { draft = ""; onChange(nil); dismiss() } label: {
                        TronSettingsRow(icon: "arrow.uturn.backward", title: "Follow the default")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .tronSaveToolbar(enabled: !draft.isEmpty) { let value = draft; draft = ""; onChange(.string(value)); dismiss() }
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
                            // The standard value row: label left, a fixed-width field right.
                            TronSettingsRow(icon: nil, title: field.label) {
                                HStack(spacing: 6) {
                                    TextField("Not set", text: Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 }))
                                        .keyboardType(.numbersAndPunctuation)
                                        .tronTextEntryDone(focus: $editing)
                                        .tronInlineField(monospaced: true)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 120)
                                        .accessibilityLabel(field.label)
                                    if let unit = range.unit {
                                        Text(unit)
                                            .font(TronTypography.secondaryDescription)
                                            .foregroundStyle(Color.tronTextSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .tronSettingsCaption(help)
                if payload == nil {
                    TronSettingsNotice(message: "Enter whole numbers within the offered range.")
                }
            }.padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .tronSaveToolbar(enabled: payload != nil) {
            guard let payload else { return }
            editing = false
            onChange(payload)
            dismiss()
        }
    }
}

/// String values keep stable local row identity while editing, in the order the
/// Gateway stores them; each row can move earlier or later. A key whose values
/// come from a served catalog (`entryPicker`) adds through that picker instead of
/// a text field. The Gateway alone validates item syntax, count and allowed
/// values on Save.
struct SettingsListEditor: View {
    private struct Item: Identifiable { let id = UUID(); var text: String }
    let title: String
    let help: String
    /// The schema's guidance for one new value: its format and a realistic example.
    let entry: SettingsEntryGuidance?
    /// A served picker for new values (model queues pick from the model catalog).
    var entryPicker: ((@escaping (String) -> Void) -> AnyView)? = nil
    let onChange: (JSONValue?) -> Void
    @State private var items: [Item]
    @State private var next = ""
    @Environment(\.dismiss) private var dismiss

    init(title: String, help: String, entry: SettingsEntryGuidance?, values: [String],
         entryPicker: ((@escaping (String) -> Void) -> AnyView)? = nil, onChange: @escaping (JSONValue?) -> Void) {
        self.title = title; self.help = help; self.entry = entry; self.entryPicker = entryPicker; self.onChange = onChange
        _items = State(initialValue: values.map { Item(text: $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TronSettingsGroup(title) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { TronSettingsDivider() }
                        // One control per action. Direct buttons, not a Menu: SwiftUI menus
                        // fail to open in a sheet presented from another sheet (#877).
                        TronSettingsRow(icon: nil, title: item.text) {
                            HStack(spacing: 0) {
                                if items.count > 1 {
                                    moveButton(item.text, earlier: true, enabled: index > 0) { move(item.id, by: -1) }
                                    moveButton(item.text, earlier: false, enabled: index < items.count - 1) { move(item.id, by: 1) }
                                }
                                removeButton(item.text) { items.removeAll { $0.id == item.id } }
                            }
                        }
                    }
                    if items.isEmpty { TronSettingsRow(icon: nil, title: "None") }
                }
                .tronSettingsCaption(help)
                if let entryPicker {
                    TronSelectionSheetRow(icon: "plus", title: "Add model", value: "Choose") {
                        entryPicker { value in if !items.contains(where: { $0.text == value }) { items.append(Item(text: value)) } }
                    }
                    .tronGlassSurface(accent: .tronEmerald)
                } else {
                    TronSettingsRow(icon: "plus", title: "Add value") {
                        TextField("Value", text: $next,
                                  prompt: entry.map { Text($0.example).foregroundStyle(Color.tronTextMuted) })
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronInlineField(monospaced: true)
                            .tronTextEntryDone(onDone: add)
                            .accessibilityLabel("Value")
                            .accessibilityIdentifier("settings-list-add-value")
                            .accessibilityHint(entry?.hint ?? "")
                        Button(action: add) { TronInlineActionLabel("Add") }
                            .buttonStyle(.plain).disabled(next.isEmpty)
                    }
                    .tronGlassSurface(accent: .tronEmerald)
                    .tronSettingsCaption(entry.map { "\($0.hint) For example: \($0.example)" })
                }
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .tronSaveToolbar { onChange(.array(items.map { .string($0.text) })); dismiss() }
    }

    /// Done on the keyboard adds what was typed, like the Add button; Save still commits the list.
    private func add() {
        guard !next.isEmpty else { return }
        items.append(Item(text: next)); next = ""
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
    }

    /// The queued-message vocabulary: Move earlier / Move later with arrow icons.
    private func moveButton(_ item: String, earlier: Bool, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: earlier ? "arrow.up" : "arrow.down")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(enabled ? Color.tronTextSecondary : Color.tronTextMuted)
                .frame(width: 32, height: 32)
                .glassEffect(.regular.interactive(), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(earlier ? "Move \(item) earlier" : "Move \(item) later")
    }

    private func removeButton(_ item: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronError)
                .frame(width: 36, height: 32)
                .glassEffect(.regular.tint(Color.tronError.opacity(0.10)).interactive(), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(item)")
    }
}
