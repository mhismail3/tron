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
