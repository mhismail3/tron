import SwiftUI

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
    @State private var rebuildGeneration = 0
    @State private var rebuildTask: Task<Void, Never>?
    @State private var localTransformationTask: Task<Void, Never>?
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
                    Button("Load JSON into Guided Editor") {
                        localTransformationTask?.cancel()
                        localTransformationTask = Task {
                            await loadDraftsFromDocument()
                            if !Task.isCancelled { localTransformationTask = nil }
                        }
                    }
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
        .onDisappear {
            rebuildTask?.cancel()
            rebuildTask = nil
            localTransformationTask?.cancel()
            localTransformationTask = nil
        }
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
        await loadFromProjection()
    }

    private func loadFromProjection() async {
        guard !saving, draftOwner.admitsPublication,
              let root = model.customModels(for: target)?.objectValue else { return }
        let value = root["document"] ?? .object(["providers": .object([:])])
        do {
            let prepared = try await prepareOffMain(value)
            guard !saving, draftOwner.admitsPublication,
                  model.customModels(for: target)?.objectValue == root else { return }
            install(prepared)
            redacted = root["redacted"]?.boolValue ?? false
            draftOwner.markInstalled()
        } catch is CancellationError {
        } catch {
            model.presentConfigurationActionError(error)
        }
    }

    private func rebuildDocument() {
        guard !advancedDocumentEdited else { return }
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        let root = documentRoot
        let providerSnapshot = providers
        rebuildTask?.cancel()
        rebuildTask = Task {
            do {
                let rendered = try await renderOffMain(root: root, providers: providerSnapshot)
                try Task.checkCancellation()
                guard generation == rebuildGeneration, !advancedDocumentEdited else { return }
                documentRoot = rendered.root
                document = rendered.document
                rebuildTask = nil
            } catch is CancellationError {
            } catch {
                guard generation == rebuildGeneration else { return }
                rebuildTask = nil
            }
        }
    }

    private func loadDraftsFromDocument() async {
        let source = document
        do {
            let prepared = try await decodeOffMain(source)
            guard document == source, advancedDocumentEdited else { return }
            install(prepared)
            advancedDocumentEdited = false
            draftOwner.markEdited()
            showingAdvanced = false
        } catch is CancellationError {
        } catch {
            guard document == source else { return }
            model.presentConfigurationActionError(error)
        }
    }

    private func install(_ prepared: PreparedCustomModelDraft) {
        rebuildGeneration &+= 1
        rebuildTask?.cancel()
        rebuildTask = nil
        documentRoot = prepared.root
        providers = prepared.providers
        document = prepared.document
    }

    private func prepareOffMain(_ value: JSONValue) async throws -> PreparedCustomModelDraft {
        let task = Task.detached(priority: .userInitiated) {
            try CustomModelDraftTransformation.prepare(value)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func decodeOffMain(_ source: String) async throws -> PreparedCustomModelDraft {
        let task = Task.detached(priority: .userInitiated) {
            try CustomModelDraftTransformation.decodeAdvanced(source)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func decodeValueOffMain(_ source: String) async throws -> JSONValue {
        let task = Task.detached(priority: .userInitiated) {
            guard let data = source.data(using: .utf8) else {
                throw CustomModelDraftTransformationError.invalidRoot
            }
            return try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func renderOffMain(
        root: [String: JSONValue],
        providers: [CustomModelProviderDraft]
    ) async throws -> RenderedCustomModelDraft {
        let task = Task.detached(priority: .userInitiated) {
            try CustomModelDraftTransformation.rebuild(root: root, providers: providers)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private var providerRemovalName: String {
        guard let providerToRemove else { return "this provider" }
        return providerToRemove.identifier.isEmpty ? "this provider" : providerToRemove.identifier
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let submittedRevision = draftOwner.beginSave()
            let value: JSONValue
            if advancedDocumentEdited {
                value = try await decodeValueOffMain(document)
            } else {
                let root = documentRoot
                let providerSnapshot = providers
                let rendered = try await renderOffMain(root: root, providers: providerSnapshot)
                value = rendered.value
                if root == documentRoot, providerSnapshot == providers {
                    rebuildGeneration &+= 1
                    rebuildTask?.cancel()
                    rebuildTask = nil
                    documentRoot = rendered.root
                    document = rendered.document
                }
            }
            try await model.replaceCustomModelsAndRestart(value, target: target)
            if draftOwner.completeSave(revision: submittedRevision) {
                advancedDocumentEdited = false
            }
        } catch { model.presentConfigurationActionError(error) }
    }
}
