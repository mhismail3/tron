import SwiftUI

// MARK: - Glass Text Field (iOS 26 Liquid Glass)

@available(iOS 26.0, *)
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
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.15)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

// MARK: - Text Field with History Navigation

struct TextFieldWithHistory: View {
    @Binding var text: String
    let isProcessing: Bool
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void
    var inputHistory: InputHistoryStore?
    var onHistoryNavigate: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            // History indicator
            if let history = inputHistory, history.isNavigating,
               let position = history.navigationPosition {
                Text("History: \(position)")
                    .font(TronTypography.caption2)
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                // History navigation buttons
                if inputHistory != nil {
                    historyNavigationButtons
                }

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
    }

    // MARK: - History Navigation

    private var historyNavigationButtons: some View {
        VStack(spacing: 2) {
            Button {
                navigateHistoryUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isProcessing || inputHistory?.history.isEmpty == true)

            Button {
                navigateHistoryDown()
            } label: {
                Image(systemName: "chevron.down")
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isProcessing || inputHistory?.isNavigating != true)
        }
    }

    private func navigateHistoryUp() {
        guard let history = inputHistory else { return }
        if let newText = history.navigateUp(currentInput: text) {
            onHistoryNavigate?(newText)
        }
    }

    private func navigateHistoryDown() {
        guard let history = inputHistory else { return }
        if let newText = history.navigateDown() {
            onHistoryNavigate?(newText)
        }
    }
}

