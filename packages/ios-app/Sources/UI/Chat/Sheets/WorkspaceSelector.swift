import SwiftUI

// MARK: - Workspace Selector

struct WorkspaceSelector: View {
    @Binding var selectedPath: String

    @Environment(\.dismiss) private var dismiss
    @State private var draftPath = ""
    @FocusState private var pathFieldFocused: Bool

    private var trimmedPath: String {
        draftPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedPath.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Workspace path", text: $draftPath, axis: .vertical)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(.tronTextPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(3, reservesSpace: true)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($pathFieldFocused)
                    .padding(14)
                    .background(.tronSurface.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.tronBorder.opacity(0.7), lineWidth: 1)
                    )
                    .submitLabel(.done)
                    .onSubmit(save)

                Text("Enter the path as it exists on the paired Mac.")
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronTextMuted)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Workspace")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: save) {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? Color.tronEmerald : Color.tronOverlay(0.3))
                }
            }
            .onAppear {
                draftPath = selectedPath
                pathFieldFocused = true
            }
        }
        .adaptivePresentationDetents([.medium], ipadSizing: .largeForm)
    }

    private func save() {
        guard canSave else { return }
        selectedPath = trimmedPath
        dismiss()
    }
}
