import SwiftUI

// MARK: - Glass Text Field (iOS 26 Liquid Glass)

struct GlassTextField: View {
    @Binding var text: String
    let isProcessing: Bool
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void

    // Trailing padding to accommodate morph docks
    var trailingPadding: CGFloat = 14

    var body: some View {
        ZStack(alignment: .leading) {
            // Placeholder overlay - only show when empty AND not focused
            if text.isEmpty && !isFocused {
                Text("Type here")
                    .font(TronTypography.input)
                    .foregroundStyle(.tronEmerald.opacity(0.5))
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TronTypography.input)
                .foregroundStyle(.tronEmerald)
                .padding(.leading, 14)
                .padding(.trailing, trailingPadding)
                .padding(.vertical, 10)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(isProcessing)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSubmit()
                    }
                }
        }
        .frame(minHeight: 40)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Simplified Text Field (without history navigation)

struct SimplifiedTextField: View {
    @Binding var text: String
    let isProcessing: Bool
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            // Placeholder overlay - only show when empty AND not focused
            if text.isEmpty && !isFocused {
                Text("Type here")
                    .font(TronTypography.input)
                    .foregroundStyle(.tronEmerald.opacity(0.5))
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TronTypography.input)
                .foregroundStyle(.tronEmerald)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(isProcessing)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSubmit()
                    }
                }
        }
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
