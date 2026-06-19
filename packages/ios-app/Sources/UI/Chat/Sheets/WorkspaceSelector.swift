import SwiftUI

// MARK: - Workspace Selector

struct WorkspaceSelector: View {
    @Binding var selectedPath: String
    let options: [WorkspaceSelectionOption]

    @Environment(\.dismiss) private var dismiss
    @State private var draftPath = ""
    @FocusState private var pathFieldFocused: Bool

    init(
        selectedPath: Binding<String>,
        options: [WorkspaceSelectionOption] = []
    ) {
        self._selectedPath = selectedPath
        self.options = options
    }

    private var trimmedPath: String {
        draftPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedPath.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if !options.isEmpty {
                        suggestedWorkspaces
                    }

                    manualPathEntry
                }
                .padding(20)
            }
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
                    Text("Select Workspace")
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
                pathFieldFocused = options.isEmpty
            }
        }
        .adaptivePresentationDetents([.medium], ipadSizing: .largeForm)
    }

    private var suggestedWorkspaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
                .textCase(.uppercase)

            VStack(spacing: 8) {
                ForEach(options) { option in
                    WorkspaceSelectionOptionRow(
                        option: option,
                        isSelected: option.path == trimmedPath
                    ) {
                        select(option)
                    }
                }
            }
        }
    }

    private var manualPathEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual path")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
                .textCase(.uppercase)

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
        }
    }

    private func select(_ option: WorkspaceSelectionOption) {
        draftPath = option.path
        selectedPath = option.path
        dismiss()
    }

    private func save() {
        guard canSave else { return }
        selectedPath = trimmedPath
        dismiss()
    }
}

private struct WorkspaceSelectionOptionRow: View {
    let option: WorkspaceSelectionOption
    let isSelected: Bool
    let action: () -> Void

    private var icon: String {
        switch option.source {
        case .defaultWorkspace:
            return "house.fill"
        case .recent:
            return "clock.arrow.circlepath"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)

                    Text(option.subtitle)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(isSelected ? 0.22 : 0.12)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
