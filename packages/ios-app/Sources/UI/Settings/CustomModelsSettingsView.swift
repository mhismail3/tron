import SwiftUI

private struct CustomModelProviderDraft: Identifiable, Hashable {
    let id: UUID
    var identifier: String
    var baseURL: String
    var api: String
    var models: String
    var original: [String: JSONValue]

    init(
        id: UUID = UUID(),
        identifier: String = "",
        baseURL: String = "",
        api: String = "openai-completions",
        models: String = "",
        original: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.identifier = identifier
        self.baseURL = baseURL
        self.api = api
        self.models = models
        self.original = original
    }
}

struct CustomModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    private let target = CustomModelTarget.global
    @State private var document = ""
    @State private var documentRoot: [String: JSONValue] = [:]
    @State private var providers: [CustomModelProviderDraft] = []
    @State private var redacted = false
    @State private var showingAdvanced = false
    @State private var advancedDocumentEdited = false
    @State private var draftOwner = CustomModelDraftOwner()
    @State private var saving = false
    @State private var providerToRemove: CustomModelProviderDraft?
    @FocusState private var advancedEditorFocused: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                if redacted {
                    Label("Secret-looking values are hidden. Tron preserves them when you save; manage provider credentials from Providers.", systemImage: "key.slash")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.10)
                }

                TronSettingsGroup("Providers", detail: "Add OpenAI-compatible or provider-native endpoints. Authentication remains in the Mac credential store.", accent: .tronPurple) {
                    if providers.isEmpty {
                        TronSettingsRow(
                            icon: "cpu",
                            title: "No custom providers",
                            subtitle: "Built-in providers are unchanged.",
                            accent: .tronPurple
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach($providers) { $provider in
                                if provider.id != providers.first?.id { TronSettingsDivider(accent: .tronPurple) }
                                customProviderEditor($provider)
                            }
                        }
                    }
                }
                .disabled(advancedDocumentEdited)

                if advancedDocumentEdited {
                    Label("Advanced JSON has unsaved edits. Save it directly, or reload it into the guided editor.", systemImage: "curlybraces")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.09)
                    Button("Load JSON into Guided Editor") { loadDraftsFromDocument() }
                        .buttonStyle(TronActionButtonStyle())
                }

                Button {
                    providers.append(CustomModelProviderDraft())
                    draftOwner.markEdited()
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .buttonStyle(TronActionButtonStyle())
                .disabled(advancedDocumentEdited)

                DisclosureGroup(isExpanded: $showingAdvanced) {
                    TextEditor(text: $document)
                        .frame(minHeight: 300)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .tronTextEditor(monospaced: true)
                        .padding(.top, 12)
                        .focused($advancedEditorFocused)
                        .onChange(of: document) { _, _ in
                            if advancedEditorFocused {
                                advancedDocumentEdited = true
                                draftOwner.markEdited()
                            }
                        }
                } label: {
                    Label("Advanced JSON", systemImage: "curlybraces")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                }
                .padding(14)
                .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08)

                Button(saving ? "Validating…" : "Save and Restart") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(saving || (!advancedDocumentEdited && providers.contains(where: { $0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })))
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Custom Models")
        .task(id: CustomModelLoadID(
            target: target,
            invalidationGeneration: model.customModelInvalidationGeneration
        )) { await load() }
        .alert(
            "Remove \(providerRemovalName)?",
            isPresented: Binding(get: { providerToRemove != nil }, set: { if !$0 { providerToRemove = nil } })
        ) {
            Button("Cancel", role: .cancel) { providerToRemove = nil }
            Button("Remove Provider", role: .destructive) {
                if let providerToRemove { providers.removeAll { $0.id == providerToRemove.id } }
                providerToRemove = nil
                draftOwner.markEdited()
                rebuildDocument()
            }
        }
    }

    private func customProviderEditor(_ provider: Binding<CustomModelProviderDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.wrappedValue.identifier.isEmpty ? "New Provider" : provider.wrappedValue.identifier)
                    .font(TronTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
                Spacer()
                Button(role: .destructive) { providerToRemove = provider.wrappedValue } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.tronError)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Remove provider")
            }
            TextField("Provider identifier", text: provider.identifier)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronField(monospaced: true, compact: true)
            TextField("Base URL", text: provider.baseURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronField(monospaced: true, compact: true)
            TronValueRow(icon: "network", title: "API format", accent: .tronPurple) {
                TronInlineMenu(apiTitle(provider.wrappedValue.api), accent: .tronPurple) {
                    Button("Inherited / per model") { provider.wrappedValue.api = "" }
                    Button("OpenAI Chat Completions") { provider.wrappedValue.api = "openai-completions" }
                    Button("OpenAI Responses") { provider.wrappedValue.api = "openai-responses" }
                    Button("Anthropic Messages") { provider.wrappedValue.api = "anthropic-messages" }
                    Button("Google Generative AI") { provider.wrappedValue.api = "google-generative-ai" }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Model IDs · one per line")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextSecondary)
                TextField("model-id", text: provider.models, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .tronField(monospaced: true, compact: true)
            }
        }
        .padding(14)
        .onChange(of: provider.wrappedValue) { _, _ in
            draftOwner.markEdited()
            rebuildDocument()
        }
    }

    private func apiTitle(_ api: String) -> String {
        switch api {
        case "openai-responses": "OpenAI Responses"
        case "anthropic-messages": "Anthropic Messages"
        case "google-generative-ai": "Google Generative AI"
        case "": "Inherited / per model"
        default: "OpenAI Chat"
        }
    }

    private func load() async {
        guard await model.loadCustomModels(target: target) else { return }
        loadFromProjection()
    }

    private func loadFromProjection() {
        guard !saving, draftOwner.admitsPublication,
              let root = model.customModels(for: target)?.objectValue else { return }
        let value = root["document"] ?? .object(["providers": .object([:])])
        documentRoot = value.objectValue ?? [:]
        document = value.prettyPrinted
        redacted = root["redacted"]?.boolValue ?? false
        loadDrafts(from: value)
        draftOwner.markInstalled()
    }

    private func rebuildDocument() {
        guard !advancedDocumentEdited else { return }
        var values: [String: JSONValue] = [:]
        for provider in providers {
            let identifier = provider.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            var object = provider.original
            if provider.api.isEmpty { object.removeValue(forKey: "api") }
            else { object["api"] = .string(provider.api) }
            if provider.baseURL.isEmpty { object.removeValue(forKey: "baseUrl") }
            else { object["baseUrl"] = .string(provider.baseURL) }
            let ids = provider.models.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let existingModels = (object["models"]?.arrayValue ?? []).reduce(into: [String: JSONValue]()) { result, value in
                if let id = value.objectValue?["id"]?.stringValue { result[id] = value }
            }
            if ids.isEmpty { object.removeValue(forKey: "models") }
            else {
                object["models"] = .array(ids.map { id in
                    existingModels[id] ?? .object(["id": .string(id), "name": .string(id)])
                })
            }
            values[identifier] = .object(object)
        }
        documentRoot["providers"] = .object(values)
        document = JSONValue.object(documentRoot).prettyPrinted
    }

    private func loadDraftsFromDocument() {
        guard let data = document.data(using: .utf8),
              let value = try? JSONDecoder.gateway.decode(JSONValue.self, from: data) else {
            model.lastError = "Advanced JSON is not valid JSON."
            return
        }
        documentRoot = value.objectValue ?? [:]
        document = value.prettyPrinted
        loadDrafts(from: value)
        advancedDocumentEdited = false
        draftOwner.markEdited()
        showingAdvanced = false
    }

    private var providerRemovalName: String {
        guard let providerToRemove else { return "this provider" }
        return providerToRemove.identifier.isEmpty ? "this provider" : providerToRemove.identifier
    }

    private func loadDrafts(from value: JSONValue) {
        providers = value.objectValue?["providers"]?.objectValue?.sorted(by: { $0.key < $1.key }).map { identifier, value in
            let object = value.objectValue ?? [:]
            let modelIDs = object["models"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }.joined(separator: "\n") ?? ""
            return CustomModelProviderDraft(
                identifier: identifier,
                baseURL: object["baseUrl"]?.stringValue ?? "",
                api: object["api"]?.stringValue ?? "",
                models: modelIDs,
                original: object
            )
        } ?? []
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if !advancedDocumentEdited { rebuildDocument() }
            guard let data = document.data(using: .utf8) else { return }
            let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
            let submittedRevision = draftOwner.beginSave()
            try await model.replaceCustomModelsAndRestart(value, target: target)
            if draftOwner.completeSave(revision: submittedRevision) {
                advancedDocumentEdited = false
            }
        } catch { model.presentConfigurationActionError(error) }
    }
}
