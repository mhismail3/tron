import SwiftUI

struct CustomModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronPresentationActivity) private var presentationActivity
    private let target = CustomModelTarget.global
    @State private var document = ""
    @State private var documentRoot: [String: JSONValue] = [:]
    @State private var providers: [CustomModelProviderDraft] = []
    @State private var redacted = false
    @State private var showingAdvanced = false
    @State private var advancedDocumentEdited = false
    @State private var draftOwner = CustomModelDraftOwner()
    private var saving: Bool { model.configurationAutosave.hasPending(.customModels(target)) }
    @State private var rebuildGeneration = 0
    @State private var rebuildTask: Task<Void, Never>?
    @State private var localTransformationTask: Task<Void, Never>?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                SettingsAutosaveNotice(key: .customModels(target))
                providersSection
                    .disabled(advancedDocumentEdited)
                    .tronSettingsCaption("Valid changes save automatically. Restart the Gateway manually when ready to activate changes to its model registry.")

                if advancedDocumentEdited {
                    Button("Load JSON into Guided Editor") {
                        localTransformationTask?.cancel()
                        localTransformationTask = Task {
                            await loadDraftsFromDocument()
                            if !Task.isCancelled { localTransformationTask = nil }
                        }
                    }
                        .buttonStyle(TronActionButtonStyle())
                        .tronSettingsCaption("Advanced JSON is active and saves automatically when valid. Load it into the guided editor to continue there.")
                }

                TronTechnicalJSONRow(
                    value: .object(documentRoot),
                    title: "Advanced JSON",
                    subtitle: "View or edit full custom model configuration",
                    sheetTitle: "Advanced JSON",
                    accent: .tronSlate,
                    onEdit: {
                        Task { @MainActor in
                            await Task.yield()
                            showingAdvanced = true
                        }
                    }
                )
                .tronSettingsCaption(redacted ? "Secret-looking values are hidden and preserved automatically. Manage provider credentials from Providers." : nil)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Custom Models")
        .onSubmit { model.configurationAutosave.flush() }
        .onChange(of: model.configurationAutosave.inputGeneration) { _, _ in
            install(PreparedCustomModelDraft(root: [:], providers: [], document: ""))
            draftOwner = CustomModelDraftOwner()
            advancedDocumentEdited = false
            showingAdvanced = false
        }
        .tronManagedSheet(
            isPresented: $showingAdvanced,
            identity: "settings.custom-model.advanced"
        ) {
            advancedEditorSheet
        }
        .task(id: PresentationActivityTaskID(
            source: CustomModelLoadID(
                target: target,
                invalidationGeneration: model.customModelInvalidationGeneration,
                foregroundGeneration: model.foregroundReconciliationGeneration
            ),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await load()
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            guard !active else { return }
            rebuildTask?.cancel()
            rebuildTask = nil
            localTransformationTask?.cancel()
            localTransformationTask = nil
        }
        .onDisappear {
            model.configurationAutosave.flush()
            rebuildTask?.cancel()
            rebuildTask = nil
            localTransformationTask?.cancel()
            localTransformationTask = nil
        }
    }

    private var advancedEditorSheet: some View {
        CustomModelAdvancedEditorSheet(document: editedAdvancedDocumentBinding, target: target) {
            showingAdvanced = false
        }
    }

    private var providersSection: some View {
        LazyVStack(alignment: .leading, spacing: TronSpacing.md) {
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text("Providers")
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose a provider to edit its endpoint, format, and model IDs.")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if providers.isEmpty {
                TronSettingsCaption("No custom providers. Built-in providers are unchanged.")
            } else {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            }

            Button {
                providers.append(CustomModelProviderDraft())
                draftOwner.markEdited()
                enqueueAutosave()
            } label: {
                TronSettingsRow(
                    icon: "plus",
                    title: "Add Provider",
                    accent: .tronEmerald,
                    titleColor: TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme)
                        ? .white
                        : settingsTheme?.accent ?? .tronEmerald
                )
            }
            .buttonStyle(.plain)
            .tronGlassSurface(accent: .tronPurple, interactive: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerRow(_ provider: CustomModelProviderDraft) -> some View {
        let inputGeneration = model.configurationAutosave.inputGeneration
        let modelCount = provider.models
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        let modelLabel = modelCount == 0 ? "No model IDs" : "\(modelCount) model \(modelCount == 1 ? "ID" : "IDs")"
        let endpoint = provider.baseURL.isEmpty ? "Add an endpoint" : provider.baseURL
        let secondaryLine = "\(endpoint) · \(modelLabel) · \(apiTitle(provider.api))"

        return TronSettingsRow(icon: "cpu", title: provider.identifier.isEmpty ? "New Provider" : provider.identifier,
                               subtitle: secondaryLine, titleIsIdentifier: true, subtitleColor: .tronTextSecondary) {
            TronProgressiveSheetLink(accessibilityLabel: "Configure \(provider.identifier)",
                                     identity: "settings.custom-model.\(provider.id)") {
                CustomModelProviderConfiguration(provider: provider, onRemove: {
                    guard inputGeneration == model.configurationAutosave.inputGeneration,
                          !advancedDocumentEdited, providers.contains(where: { $0.id == provider.id }) else { return }
                    providers.removeAll { $0.id == provider.id }
                    draftOwner.markEdited()
                    rebuildDocument()
                    enqueueAutosave()
                }) {
                    providerEditorSheet(provider.editingBinding(in: $providers))
                }
            } label: { TronInlineActionLabel("Configure") }
        }
        .tronGlassSurface(accent: .tronPurple)
    }

    private func providerEditorSheet(_ provider: Binding<CustomModelProviderDraft>) -> some View {
        let providerID = provider.wrappedValue.id
        let api = editedProviderBinding(provider.api, providerID: providerID)
        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                SettingsAutosaveNotice(key: .customModels(target))
                TronSettingsGroup("Connection") {
                    VStack(spacing: 0) {
                        TronTextSettingRow(icon: "cpu", title: "Provider ID", value: editedProviderBinding(provider.identifier, providerID: providerID))
                        TronSettingsDivider()
                        TronTextSettingRow(icon: "network", title: "Base URL", value: editedProviderBinding(provider.baseURL, providerID: providerID), keyboard: .URL)
                    }
                }
                TronSettingsGroup("Models", detail: "One model ID per line. These appear in model selection.", accent: .tronBlue, surfaceStyle: .glass) {
                    TextField("Model IDs", text: editedProviderBinding(provider.models, providerID: providerID), axis: .vertical)
                        .lineLimit(2...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .tronField(monospaced: true, surfaceTint: Color.tronBlue.opacity(0.15), border: Color.tronBlue.opacity(0.30))
                }
                TronSettingsGroup("Protocol") {
                    TronSelectionRow(icon: "network", title: "API Format", value: apiTitle(api.wrappedValue)) {
                        Button("Inherited / per model") { api.wrappedValue = "" }
                        Button("OpenAI Chat Completions") { api.wrappedValue = "openai-completions" }
                        Button("OpenAI Responses") { api.wrappedValue = "openai-responses" }
                        Button("Anthropic Messages") { api.wrappedValue = "anthropic-messages" }
                        Button("Google Generative AI") { api.wrappedValue = "google-generative-ai" }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(provider.wrappedValue.identifier.isEmpty ? "New Provider" : provider.wrappedValue.identifier)
    }

    private var editedAdvancedDocumentBinding: Binding<String> {
        let profile = model.profileRevision
        let inputGeneration = model.configurationAutosave.inputGeneration
        return Binding(
            get: { document },
            set: { value in
                guard model.profileRevision == profile, presentationActivity.allowsDataPublication,
                      model.configurationAutosave.inputGeneration == inputGeneration,
                      draftOwner.markEdited(from: document, to: value) else { return }
                document = value
                advancedDocumentEdited = true
                rebuildDocument()
                enqueueAutosave()
            }
        )
    }

    private func editedProviderBinding<Value: Equatable>(_ binding: Binding<Value>, providerID: UUID) -> Binding<Value> {
        let profile = model.profileRevision
        let inputGeneration = model.configurationAutosave.inputGeneration
        let initial = binding.wrappedValue
        return Binding(
            get: { model.profileRevision == profile && model.configurationAutosave.inputGeneration == inputGeneration ? binding.wrappedValue : initial },
            set: { value in
                guard model.profileRevision == profile, presentationActivity.allowsDataPublication,
                      model.configurationAutosave.inputGeneration == inputGeneration,
                      providers.contains(where: { $0.id == providerID }), !advancedDocumentEdited,
                      draftOwner.markEdited(from: binding.wrappedValue, to: value) else { return }
                binding.wrappedValue = value
                rebuildDocument()
                enqueueAutosave()
            }
        )
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
        let foreground = model.foregroundReconciliationGeneration
        guard presentationActivity.allowsPresentationPublication,
              await model.loadCustomModels(target: target),
              foreground == model.foregroundReconciliationGeneration, !Task.isCancelled,
              presentationActivity.allowsPresentationPublication else { return }
        await loadFromProjection()
    }

    private func loadFromProjection() async {
        let foreground = model.foregroundReconciliationGeneration
        guard presentationActivity.allowsPresentationPublication,
              !saving, !advancedDocumentEdited, draftOwner.admitsPublication,
              let root = model.customModels(for: target)?.objectValue else { return }
        let value = root["document"] ?? .object(["providers": .object([:])])
        do {
            let prepared = try await prepareOffMain(value)
            guard !Task.isCancelled, foreground == model.foregroundReconciliationGeneration,
                  presentationActivity.allowsPresentationPublication,
                  !saving, !advancedDocumentEdited, draftOwner.admitsPublication,
                  model.customModels(for: target)?.objectValue == root else { return }
            install(prepared)
            redacted = root["redacted"]?.boolValue ?? false
            draftOwner.markInstalled()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, foreground == model.foregroundReconciliationGeneration,
                  presentationActivity.allowsPresentationPublication else { return }
            model.presentConfigurationActionError(error)
        }
    }

    private func rebuildDocument() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        let profile = model.profileRevision
        let inputGeneration = model.configurationAutosave.inputGeneration
        let root = documentRoot
        let providerSnapshot = providers
        let advanced = advancedDocumentEdited ? document : nil
        rebuildTask?.cancel()
        rebuildTask = Task {
            do {
                if let advanced {
                    let prepared = try await decodeOffMain(advanced)
                    guard !Task.isCancelled, generation == rebuildGeneration, model.profileRevision == profile,
                          model.configurationAutosave.inputGeneration == inputGeneration,
                          presentationActivity.allowsDataPublication else { return }
                    documentRoot = prepared.root // Never reformat beneath an active caret.
                } else {
                    let rendered = try await renderOffMain(root: root, providers: providerSnapshot)
                    guard !Task.isCancelled, generation == rebuildGeneration, model.profileRevision == profile,
                          model.configurationAutosave.inputGeneration == inputGeneration,
                          presentationActivity.allowsDataPublication else { return }
                    documentRoot = rendered.root
                    document = rendered.document
                }
                rebuildTask = nil
            } catch {
                guard generation == rebuildGeneration, model.profileRevision == profile,
                      model.configurationAutosave.inputGeneration == inputGeneration else { return }
                rebuildTask = nil
            }
        }
    }

    private func loadDraftsFromDocument() async {
        let source = document
        let revision = draftOwner.revision
        let inputGeneration = model.configurationAutosave.inputGeneration
        do {
            let prepared = try await decodeOffMain(source)
            guard !Task.isCancelled, document == source, advancedDocumentEdited,
                  revision == draftOwner.revision, inputGeneration == model.configurationAutosave.inputGeneration,
                  presentationActivity.allowsDataPublication else { return }
            install(prepared)
            advancedDocumentEdited = false
            draftOwner.markEdited()
            showingAdvanced = false
            enqueueAutosave()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, document == source, revision == draftOwner.revision,
                  inputGeneration == model.configurationAutosave.inputGeneration,
                  presentationActivity.allowsDataPublication else { return }
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

    private func enqueueAutosave() {
        guard draftOwner.isDirty else { return }
        let revision = draftOwner.revision
        let profile = model.profileRevision
        let inputGeneration = model.configurationAutosave.inputGeneration
        let root = documentRoot
        let providerSnapshot = providers
        let advanced = advancedDocumentEdited ? document : nil
        let target = target
        model.configurationAutosave.submit(key: .customModels(target), write: { [weak model] _ in
            guard let model, model.profileRevision == profile,
                  model.configurationAutosave.inputGeneration == inputGeneration else { throw CancellationError() }
            let preparation = Task.detached(priority: .userInitiated) {
                do {
                    return try CustomModelDraftTransformation.autosaveValue(advancedDocument: advanced, root: root, providers: providerSnapshot)
                } catch { throw ConfigurationEditValidationError(message: error.localizedDescription) }
            }
            let value = try await preparation.value
            guard model.profileRevision == profile,
                  model.configurationAutosave.inputGeneration == inputGeneration else { throw CancellationError() }
            try await model.replaceCustomModels(value, target: target)
        }, completed: { [weak model] in
            guard let model, model.profileRevision == profile else { return }
            _ = draftOwner.completeSave(revision: revision)
        })
    }
}

/// The exact provider editor owns its destructive confirmation, not the list
/// behind it. Removal retires the editor and its stable-ID field bindings.
struct CustomModelProviderConfiguration<Content: View>: View {
    let provider: CustomModelProviderDraft
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var confirmingRemoval = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { confirmingRemoval = true } label: {
                        TronToolbarTextLabel("Remove", systemImage: "trash")
                    }
                    .tronToolbarAction(accent: .tronError)
                    .accessibilityIdentifier("custom-model-remove")
                }
            }
            .tronManagedSheet(isPresented: $confirmingRemoval, identity: "settings.custom-model.remove.\(provider.id)") {
                TronConfirmationSheet(title: "Remove this provider?",
                    message: provider.identifier.isEmpty ? "Remove this custom provider and its model definitions?" : "Remove \(provider.identifier) and its custom model definitions?",
                    confirmTitle: "Remove Provider", destructive: true, icon: "trash") {
                    dismiss()
                    onRemove()
                }
            }
    }
}

extension CustomModelProviderDraft {
    /// A dismissed editor can still receive native field callbacks. Resolving
    /// by UUID avoids indexing a removed row or reviving it during dismissal.
    func editingBinding(in providers: Binding<[Self]>) -> Binding<Self> {
        Binding(get: { providers.wrappedValue.first { $0.id == id } ?? self }, set: { next in
            guard next.id == id, let index = providers.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            providers.wrappedValue[index] = next
        })
    }
}

/// The editor retains native TextEditor's scrolling/selection; its viewport
/// owns blur below the navigation chrome, like the read-only JSON sheet.
struct CustomModelAdvancedEditorSheet: View {
    @Binding var document: String
    let target: CustomModelTarget
    let onDone: () -> Void
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    private var accent: Color { settingsTheme?.accent ?? .tronPurple }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SettingsAutosaveNotice(key: .customModels(target))
                TextEditor(text: $document)
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .tronTextEditor(monospaced: true)
            .padding(18)
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Advanced JSON", accent: accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM).foregroundStyle(accent)
                    }.accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
