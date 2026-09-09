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
    @State private var providerToRemove: CustomModelProviderDraft?
    @State private var rebuildGeneration = 0
    @State private var rebuildTask: Task<Void, Never>?
    @State private var localTransformationTask: Task<Void, Never>?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                SettingsAutosaveNotice(key: .customModels(target))
                providersSection
                    .disabled(advancedDocumentEdited)
                TronInfoCard(icon: "info.circle", text: "Valid changes save automatically. Restart the Gateway manually when ready to activate changes to its model registry.", accent: .tronSlate)

                if advancedDocumentEdited {
                    HStack(alignment: .center, spacing: TronSpacing.xl) {
                        Image(systemName: "curlybraces")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(settingsTheme?.accent ?? .tronCyan)
                            .frame(width: 20, height: 20, alignment: .center)
                            .accessibilityHidden(true)
                        Text("Advanced JSON is active and saves automatically when valid. Load it into the guided editor to continue there.")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, TronSpacing.xl)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                if redacted {
                    TronInfoCard(
                        icon: "key.slash",
                        text: "Secret-looking values are hidden and preserved automatically. Manage provider credentials from Providers.",
                        accent: .tronAmber
                    )
                }
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
                invalidationGeneration: model.customModelInvalidationGeneration
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
        .alert(
            "Remove \(providerRemovalName)?",
            isPresented: providerRemovalPresented
        ) {
            Button("Cancel", role: .cancel) { providerToRemove = nil }
            Button("Remove Provider", role: .destructive) {
                if let providerToRemove {
                    providers.removeAll { $0.id == providerToRemove.id }
                }
                providerToRemove = nil
                draftOwner.markEdited()
                rebuildDocument()
                enqueueAutosave()
            }
        }
        .tronManagedSystemPresentation(
            isPresented: providerRemovalPresented,
            identity: "settings.custom-model.remove-confirmation"
        )
    }

    private var providerRemovalPresented: Binding<Bool> {
        Binding(
            get: { providerToRemove != nil },
            set: { if !$0 { providerToRemove = nil } }
        )
    }

    private var advancedEditorSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SettingsAutosaveNotice(key: .customModels(target))
                TextEditor(text: editedAdvancedDocumentBinding)
            }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .tronTextEditor(monospaced: true)
                .padding(18)
                .tronScrollEdgeChrome()
                .tronNavigationTitle("Advanced JSON")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showingAdvanced = false } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .tronSettingsAccent()
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
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
                Label("No custom providers. Built-in providers are unchanged.", systemImage: "cpu")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.07)
            } else {
                ForEach($providers) { $provider in
                    providerRow($provider)
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
            .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.07, interactive: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerRow(_ provider: Binding<CustomModelProviderDraft>) -> some View {
        CustomModelProviderRow(
            provider: provider.wrappedValue,
            onRemove: { providerToRemove = provider.wrappedValue },
            destination: { providerEditorSheet(provider) }
        ) {
            providerSummary(provider.wrappedValue)
        }
    }

    private func providerSummary(_ provider: CustomModelProviderDraft) -> some View {
        let modelCount = provider.models
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        let modelLabel = modelCount == 0 ? "No model IDs" : "\(modelCount) model \(modelCount == 1 ? "ID" : "IDs")"
        let endpoint = provider.baseURL.isEmpty ? "Add an endpoint" : provider.baseURL
        let secondaryLine = "\(endpoint) · \(modelLabel) · \(apiTitle(provider.api))"

        return TronSettingsRow(icon: "cpu", title: provider.identifier.isEmpty ? "New Provider" : provider.identifier,
                               subtitle: secondaryLine, titleIsIdentifier: true, subtitleColor: .tronTextSecondary)
    }

    private func providerEditorSheet(_ provider: Binding<CustomModelProviderDraft>) -> some View {
        let api = editedProviderBinding(provider.api)
        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                SettingsAutosaveNotice(key: .customModels(target))
                TronSettingsGroup("Connection") {
                    VStack(spacing: 0) {
                        TronTextSettingRow(icon: "cpu", title: "Provider ID", value: editedProviderBinding(provider.identifier))
                        TronSettingsDivider()
                        TronTextSettingRow(icon: "network", title: "Base URL", value: editedProviderBinding(provider.baseURL), keyboard: .URL)
                    }
                }
                TronSettingsGroup("Models", detail: "One model ID per line. These appear in model selection.") {
                    TextField("Model IDs", text: editedProviderBinding(provider.models), axis: .vertical)
                        .lineLimit(2...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .tronField(monospaced: true, compact: true).padding(14)
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

    private func editedProviderBinding<Value: Equatable>(_ binding: Binding<Value>) -> Binding<Value> {
        let profile = model.profileRevision
        let inputGeneration = model.configurationAutosave.inputGeneration
        let initial = binding.wrappedValue
        return Binding(
            get: { model.profileRevision == profile && model.configurationAutosave.inputGeneration == inputGeneration ? binding.wrappedValue : initial },
            set: { value in
                guard model.profileRevision == profile, presentationActivity.allowsDataPublication,
                      model.configurationAutosave.inputGeneration == inputGeneration,
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
        guard presentationActivity.allowsPresentationPublication,
              await model.loadCustomModels(target: target),
              !Task.isCancelled,
              presentationActivity.allowsPresentationPublication else { return }
        await loadFromProjection()
    }

    private func loadFromProjection() async {
        guard presentationActivity.allowsPresentationPublication,
              !saving, !advancedDocumentEdited, draftOwner.admitsPublication,
              let root = model.customModels(for: target)?.objectValue else { return }
        let value = root["document"] ?? .object(["providers": .object([:])])
        do {
            let prepared = try await prepareOffMain(value)
            guard !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication,
                  !saving, !advancedDocumentEdited, draftOwner.admitsPublication,
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

    private var providerRemovalName: String {
        guard let providerToRemove else { return "this provider" }
        return providerToRemove.identifier.isEmpty ? "this provider" : providerToRemove.identifier
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

private struct CustomModelProviderRow<Label: View, Destination: View>: View {
    let provider: CustomModelProviderDraft
    let onRemove: () -> Void
    let destination: () -> Destination
    let label: Label
    @State private var isPresented = false

    init(
        provider: CustomModelProviderDraft,
        onRemove: @escaping () -> Void,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.provider = provider
        self.onRemove = onRemove
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { isPresented = true } label: {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit provider \(provider.identifier.isEmpty ? "New Provider" : provider.identifier)")

            Menu {
                Button("Remove Provider", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 8)
            .accessibilityLabel("Provider actions")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.07)
        .tronManagedSheet(
            isPresented: $isPresented,
            identity: "settings.custom-model.destination.\(provider.id.uuidString)"
        ) {
            NavigationStack {
                destination()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { isPresented = false } label: {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.buttonSM)
                                    .tronSettingsAccent()
                            }
                            .accessibilityLabel("Done")
                        }
                    }
            }
            .tronTopBlur(.sheet)
            .tronPresentation()
            .tronSettingsLayout()
            .presentationDragIndicator(.hidden)
        }
    }
}
