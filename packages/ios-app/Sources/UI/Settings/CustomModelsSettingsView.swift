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
                    HStack(alignment: .center, spacing: TronSpacing.xl) {
                        Image(systemName: "key.slash")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronAmber)
                            .frame(width: 20, height: 20, alignment: .center)
                            .accessibilityHidden(true)
                        Text("Secret-looking values are hidden. Tron preserves them when you save; manage provider credentials from Providers.")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, TronSpacing.xl)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.10)
                }

                providersSection
                    .disabled(advancedDocumentEdited)

                if advancedDocumentEdited {
                    HStack(alignment: .center, spacing: TronSpacing.xl) {
                        Image(systemName: "curlybraces")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronCyan)
                            .frame(width: 20, height: 20, alignment: .center)
                            .accessibilityHidden(true)
                        Text("Advanced JSON has unsaved edits. Save it directly, or reload it into the guided editor.")
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
                    subtitle: advancedDocumentEdited ? "Unsaved edits · View or edit configuration" : "View or edit full custom model configuration",
                    sheetTitle: "Advanced JSON",
                    accent: .tronSlate,
                    onEdit: {
                        Task { @MainActor in
                            await Task.yield()
                            showingAdvanced = true
                        }
                    }
                )
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Custom Models")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronSaveToolbarButton(isSaving: saving, isEnabled: canSave) {
                    Task { await save() }
                }
            }
        }
        .sheet(isPresented: $showingAdvanced) {
            advancedEditorSheet
        }
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
                if let providerToRemove {
                    providers.removeAll { $0.id == providerToRemove.id }
                }
                providerToRemove = nil
                draftOwner.markEdited()
                rebuildDocument()
            }
        }
    }

    private var advancedEditorSheet: some View {
        NavigationStack {
            TextEditor(text: $document)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .tronTextEditor(monospaced: true)
                .padding(18)
                .focused($advancedEditorFocused)
                .onChange(of: document) { _, _ in
                    if advancedEditorFocused {
                        advancedDocumentEdited = true
                        draftOwner.markEdited()
                    }
                }
                .tronScrollEdgeChrome()
                .tronNavigationTitle("Advanced JSON")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showingAdvanced = false } label: {
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
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($providers) { $provider in
                        providerRow($provider)
                    }
                }
            }

            Button {
                providers.append(CustomModelProviderDraft())
                draftOwner.markEdited()
            } label: {
                TronSettingsRow(
                    icon: "plus",
                    title: "Add Provider",
                    accent: .tronEmerald,
                    titleColor: .tronEmerald
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

        return HStack(alignment: .center, spacing: TronSpacing.xl) {
            Image(systemName: "cpu")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 20, height: 20, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.identifier.isEmpty ? "New Provider" : provider.identifier)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(secondaryLine)
                    .font(TronTypography.code(size: TronTypography.sizeBody2))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 6)
        }
    }

    private func providerEditorSheet(_ provider: Binding<CustomModelProviderDraft>) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    editorSectionHeader("Connection")
                    fieldLabel("Provider identifier")
                    TextField("ollama", text: provider.identifier)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .tronField(
                            monospaced: true,
                            compact: true,
                            dense: true,
                            surfaceTint: Color.tronEmerald.opacity(0.14),
                            border: Color.tronEmerald.opacity(0.42)
                        )
                    fieldLabel("Base URL")
                    TextField("https://example.com/v1", text: provider.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .tronField(
                            monospaced: true,
                            compact: true,
                            dense: true,
                            surfaceTint: Color.tronEmerald.opacity(0.14),
                            border: Color.tronEmerald.opacity(0.42)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    editorSectionHeader(
                        "Models",
                        detail: "Add one model ID per line. These names appear in model selection."
                    )
                    TextField("llama3:8b", text: provider.models, axis: .vertical)
                        .lineLimit(2...8)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .tronField(
                            monospaced: true,
                            compact: true,
                            dense: true,
                            surfaceTint: Color.tronEmerald.opacity(0.14),
                            border: Color.tronEmerald.opacity(0.42)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    editorSectionHeader(
                        "Protocol",
                        detail: "Choose the protocol used by this endpoint."
                    )
                    TronValueRow(icon: "network", title: "API format", accent: .tronEmerald) {
                        TronInlineMenu(apiTitle(provider.wrappedValue.api), accent: .tronEmerald) {
                            Button("Inherited / per model") { provider.wrappedValue.api = "" }
                            Button("OpenAI Chat Completions") { provider.wrappedValue.api = "openai-completions" }
                            Button("OpenAI Responses") { provider.wrappedValue.api = "openai-responses" }
                            Button("Anthropic Messages") { provider.wrappedValue.api = "anthropic-messages" }
                            Button("Google Generative AI") { provider.wrappedValue.api = "google-generative-ai" }
                        }
                    }
                    .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.07)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(provider.wrappedValue.identifier.isEmpty ? "New Provider" : provider.wrappedValue.identifier)
        .onChange(of: provider.wrappedValue) { _, _ in
            draftOwner.markEdited()
            rebuildDocument()
        }
    }

    private func editorSectionHeader(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.xs) {
            Text(title)
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextSecondary)
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

    private var canSave: Bool {
        draftOwner.isDirty && (advancedDocumentEdited || !providers.contains {
            $0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    private func save() async {
        guard canSave else { return }
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
                    .padding(.horizontal, TronSpacing.xl)
                    .padding(.vertical, 14)
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
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                destination()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { isPresented = false } label: {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.buttonSM)
                                    .foregroundStyle(Color.tronEmerald)
                            }
                            .accessibilityLabel("Done")
                        }
                    }
            }
            .tronTopBlur(.sheet)
            .tronPresentation()
            .presentationDragIndicator(.hidden)
        }
    }
}
