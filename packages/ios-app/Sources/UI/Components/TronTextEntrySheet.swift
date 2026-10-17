import SwiftUI

/// Rename is the same shared confirmation sheet as every other app decision.
/// The native field scrolls inside a bounded column; the clear control never
/// participates in that scrolling or gets displaced by a long name.
private struct TronConfirmationTextField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: TronSpacing.md) {
            TextField(placeholder, text: $text)
                .font(TronTypography.body)
                .tronTextEntryDone(focus: $focused, onDone: onSubmit)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.tronTextMuted)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, TronSpacing.xl)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.08)
        .task { focused = true }
    }
}

extension View {
    func tronTextEntrySheet(
        _ title: String,
        isPresented: Binding<Bool>,
        text: Binding<String>,
        placeholder: String,
        confirmTitle: String = "Save",
        cancelTitle: String = "Cancel",
        allowsEmpty: Bool = false,
        validation: @escaping (String) -> Bool = { _ in true },
        fileID: String = #fileID,
        line: Int = #line,
        onConfirm: @escaping (String) -> Void
    ) -> some View {
        let admitted = (allowsEmpty || !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && validation(text.wrappedValue)
        return tronManagedSheet(isPresented: isPresented, identity: "text-entry@\(fileID):\(line)", fileID: fileID, line: line) {
            TronConfirmationSheet(
                title: title, message: "", confirmTitle: confirmTitle,
                secondaryTitle: cancelTitle,
                onConfirm: { onConfirm(text.wrappedValue) },
                additionalContent: AnyView(TronConfirmationTextField(placeholder: placeholder, text: text) {
                    guard (allowsEmpty || !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                          validation(text.wrappedValue) else { return }
                    onConfirm(text.wrappedValue)
                    isPresented.wrappedValue = false
                }),
                canConfirm: admitted
            )
        }
    }
}
