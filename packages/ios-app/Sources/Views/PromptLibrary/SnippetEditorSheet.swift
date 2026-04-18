import SwiftUI

/// Modal form for creating or editing a snippet. `onSave` returns `true` on
/// success so the sheet can dismiss itself; `false` keeps the form open.
@available(iOS 26.0, *)
struct SnippetEditorSheet: View {
    let initialSnippet: PromptSnippet?
    let onSave: (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var text: String = ""
    @State private var isSaving = false
    @State private var showDiscardAlert = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, text }

    private static let nameMax = 100

    private var isCreating: Bool { initialSnippet == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !trimmedName.isEmpty
        && trimmedName.count <= Self.nameMax
        && !trimmedText.isEmpty
        && !isSaving
    }

    private var hasUnsavedChanges: Bool {
        if let initial = initialSnippet {
            return trimmedName != initial.name || text != initial.text
        }
        return !trimmedName.isEmpty || !trimmedText.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    nameCard
                    textCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(
                        title: isCreating ? "New Snippet" : "Edit Snippet",
                        color: .tronEmerald
                    )
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if hasUnsavedChanges {
                            showDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetPrimaryActionButton(
                        icon: "checkmark",
                        accent: .tronEmerald,
                        isBusy: isSaving,
                        isEnabled: canSave,
                        accessibilityLabel: "Save"
                    ) {
                        Task { await save() }
                    }
                }
            }
            .interactiveDismissDisabled(hasUnsavedChanges)
            .alert("Discard changes?", isPresented: $showDiscardAlert) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard", role: .destructive) { dismiss() }
            }
        }
        .tint(.tronEmerald)
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            if let initial = initialSnippet {
                name = initial.name
                text = initial.text
            }
            if isCreating {
                focusedField = .name
            }
        }
    }

    // MARK: - Cards

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Name")

            SettingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "textformat")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    TextField("Snippet name", text: $name)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .text }
                    Text("\(trimmedName.count)/\(Self.nameMax)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(trimmedName.count > Self.nameMax ? .tronError : .tronTextMuted)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .name }
            }

            SettingsCaption(text: "A short label so you can recognize this snippet in the list.")
        }
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Prompt Text")

            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                            .padding(.top, 8)
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Write the prompt body…")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronTextMuted.opacity(0.6))
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $text)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronTextPrimary)
                                .frame(minHeight: 180)
                                .scrollContentBackground(.hidden)
                                .focused($focusedField, equals: .text)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }

            SettingsCaption(text: "This text populates the composer when the snippet is selected.")
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        let ok = await onSave(trimmedName, text)
        isSaving = false
        if ok { dismiss() }
    }
}
