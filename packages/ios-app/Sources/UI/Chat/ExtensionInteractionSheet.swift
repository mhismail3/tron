import SwiftUI

struct ExtensionInteractionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let interaction: ExtensionInteraction
    @State private var text = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = interaction.message {
                        TronGlassCard {
                            Text(message)
                                .font(TronTypography.body)
                                .foregroundStyle(Color.tronTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                        }
                    }
                    if let expiresAt = interaction.expiresAt, let expiration = ISO8601DateFormatter().date(from: expiresAt) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(expiration.timeIntervalSince(context.date)))
                            TronValueRow(icon: "timer", title: remaining > 0 ? "Expires in \(remaining)s" : "Expired", accent: remaining > 0 ? .tronAmber : .tronError)
                                .tronGlassSurface(accent: remaining > 0 ? .tronAmber : .tronError, tintOpacity: 0.10)
                        }
                    }
                    switch interaction.method {
                    case .select:
                        ForEach(interaction.options ?? [], id: \.self) { option in
                            Button(option) { answer(.string(option)) }
                                .buttonStyle(TronActionButtonStyle())
                                .disabled(submitting)
                        }
                    case .confirm:
                        Button("Confirm") { answer(.bool(true)) }
                            .buttonStyle(TronActionButtonStyle(role: .primary))
                            .disabled(submitting)
                        Button("Decline", role: .destructive) { answer(.bool(false)) }
                            .buttonStyle(TronActionButtonStyle(role: .destructive))
                            .disabled(submitting)
                    case .input, .editor:
                        TextField(interaction.placeholder ?? "Response", text: $text, axis: interaction.method == .editor ? .vertical : .horizontal)
                            .lineLimit(interaction.method == .editor ? 5...16 : 1...1)
                            .tronField()
                            .disabled(submitting)
                    }
                }
                .padding(20)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: interaction.title) }
                ToolbarItem(placement: .confirmationAction) {
                    if interaction.method == .input || interaction.method == .editor {
                        Button("Submit") { answer(.string(text)) }
                            .tronToolbarAction(accent: .tronEmerald)
                            .disabled(submitting)
                    } else {
                        Button { cancel() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .accessibilityLabel("Done")
                        .disabled(submitting)
                    }
                }
            }
            .onAppear { text = interaction.prefill ?? "" }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
    }

    private func answer(_ value: JSONValue) {
        submit(value: value, cancelled: false)
    }

    private func cancel() {
        submit(value: nil, cancelled: true)
    }

    private func submit(value: JSONValue?, cancelled: Bool) {
        guard !submitting else { return }
        submitting = true
        Task {
            defer { submitting = false }
            do {
                try await model.answerInteraction(
                    interaction,
                    sessionID: sessionID,
                    value: value,
                    cancelled: cancelled
                )
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}
