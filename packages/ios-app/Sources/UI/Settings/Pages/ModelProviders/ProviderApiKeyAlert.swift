import SwiftUI

struct ProviderApiKeyAlertModifier: ViewModifier {
    @Binding var isPresented: Bool

    let scope: ProviderApiKeyPromptScope
    let onSave: (ProviderApiKeyPromptDraft) async -> ProviderAuthActionResult

    @State private var draft = ProviderApiKeyPromptDraft()
    @State private var isSaving = false

    private var canSave: Bool {
        draft.isValid(for: scope) && !isSaving
    }

    func body(content: Content) -> some View {
        content
            .alert(scope.title, isPresented: $isPresented) {
                if scope.showsLabelField {
                    TextField(ProviderApiKeyPrompt.labelPlaceholder, text: $draft.label)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                SecureField(ProviderApiKeyPrompt.keyPlaceholder, text: $draft.apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()

                Button(ProviderApiKeyPrompt.cancelButtonTitle, role: .cancel) {
                    resetDraft()
                }

                Button(ProviderApiKeyPrompt.saveButtonTitle) {
                    save()
                }
                .disabled(!canSave)
            }
            .onChange(of: isPresented) { _, newValue in
                guard !newValue, !isSaving else { return }
                resetDraft()
            }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task { @MainActor in
            let result = await onSave(draft)
            isSaving = false
            if result.shouldCommitLocalFormChanges {
                resetDraft()
                isPresented = false
            } else {
                isPresented = true
            }
        }
    }

    private func resetDraft() {
        draft = ProviderApiKeyPromptDraft()
        isSaving = false
    }
}

extension View {
    func providerApiKeyAlert(
        isPresented: Binding<Bool>,
        scope: ProviderApiKeyPromptScope,
        onSave: @escaping (ProviderApiKeyPromptDraft) async -> ProviderAuthActionResult
    ) -> some View {
        modifier(
            ProviderApiKeyAlertModifier(
                isPresented: isPresented,
                scope: scope,
                onSave: onSave
            )
        )
    }
}
