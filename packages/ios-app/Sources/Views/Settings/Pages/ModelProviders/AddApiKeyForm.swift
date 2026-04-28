import SwiftUI

struct AddApiKeyForm: View {
    let onAdd: (String, String) async -> ProviderAuthActionResult
    let onCancel: () -> Void

    @State private var label = ""
    @State private var key = ""
    @State private var isSaving = false

    private var isValid: Bool {
        ProviderStatusHelpers.isApiKeyFormValid(label: label, key: key)
    }

    private var canSave: Bool {
        isValid && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                TextField("Label", text: $label)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            HStack(spacing: 8) {
                Image(systemName: "key.horizontal")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                SecureField("API Key", text: $key)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .textContentType(.password)
                    .autocorrectionDisabled()
            }

            HStack(spacing: 8) {
                Button {
                    save()
                } label: {
                    Text("Save")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                }
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
                .tint(canSave ? .tronEmerald : .tronTextMuted.opacity(0.25))
                .opacity(canSave ? 1 : 0.55)

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func save() {
        guard isValid else { return }
        isSaving = true
        Task { @MainActor in
            let result = await onAdd(ProviderStatusHelpers.trimmedLabel(label), key)
            isSaving = false
            guard result.shouldCommitLocalFormChanges else { return }
            label = ""
            key = ""
        }
    }
}

#Preview("Empty form") {
    AddApiKeyForm(onAdd: { _, _ in .succeeded }, onCancel: {})
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding()
}
