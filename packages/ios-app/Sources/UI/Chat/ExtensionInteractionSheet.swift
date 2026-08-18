import SwiftUI

/// Native presentation for Pi's semantic interaction APIs. This intentionally
/// models select/confirm/input/editor only; arbitrary remote components and
/// overlays use a separate, currently deferred capability.
struct ExtensionInteractionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let interaction: ExtensionInteraction
    let onResolved: () -> Void
    @State private var text = ""
    @State private var selectedOption: String?
    @State private var confirmValue: Bool?
    @State private var submitting = false
    @State private var submissionError: String?
    @State private var currentDate = Date()

    private var isExpired: Bool {
        guard let expiresAt = interaction.expiresAt,
              let expiration = GatewayTimestamp.parse(expiresAt) else { return false }
        return currentDate >= expiration
    }

    private var canSubmit: Bool {
        guard !isExpired else { return false }
        return switch interaction.method {
        case .select: selectedOption != nil
        case .confirm: confirmValue != nil
        case .input, .editor: true
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    promptCard
                    expirationView
                    control
                    if let submissionError {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronError)
                            .accessibilityLabel("Could not submit: \(submissionError)")
                    }
                }
                .padding(20)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .accessibilityLabel(isExpired ? "Question expired" : "Cancel question")
                    .disabled(submitting || isExpired)
                }
                ToolbarItem(placement: .principal) {
                    Text("Question")
                        .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                        .foregroundStyle(Color.tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: submit) {
                        HStack(spacing: 4) {
                            if submitting { ProgressView().controlSize(.mini) }
                            Image(systemName: "paperplane.fill")
                            Text("Submit")
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(canSubmit ? Color.tronAmber : Color.tronTextMuted)
                    }
                    .accessibilityLabel("Submit answer")
                    .disabled(!canSubmit || submitting || isExpired)
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .onAppear { resetState() }
        .onChange(of: interaction.id) { _, _ in resetState() }
        .task(id: interaction.id) {
            while !Task.isCancelled {
                currentDate = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(interaction.title)
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = interaction.message, !message.isEmpty {
                Text(message)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var expirationView: some View {
        if let expiresAt = interaction.expiresAt, let expiration = GatewayTimestamp.parse(expiresAt) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(expiration.timeIntervalSince(context.date))
                TronValueRow(
                    icon: "timer",
                    title: remaining > 0 ? "Expires in \(remaining)s" : "Expired",
                    accent: remaining > 0 ? .tronAmber : .tronError
                )
                .tronGlassSurface(accent: remaining > 0 ? .tronAmber : .tronError, tintOpacity: 0.10)
            }
            .accessibilityLabel("Question expiration")
            .accessibilityValue(isExpired ? "Expired; waiting for the Gateway" : "Question is still available")
        }
    }

    @ViewBuilder
    private var control: some View {
        switch interaction.method {
        case .select:
            VStack(alignment: .leading, spacing: 8) {
                Text("Select one")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextMuted)
                ForEach(Array((interaction.options ?? []).enumerated()), id: \.offset) { _, option in
                    semanticOptionRow(option, selected: selectedOption == option) {
                        selectedOption = option
                    }
                }
            }
        case .confirm:
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose an answer")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextMuted)
                semanticOptionRow("Confirm", selected: confirmValue == true) { confirmValue = true }
                semanticOptionRow("Decline", selected: confirmValue == false, destructive: true) { confirmValue = false }
            }
        case .input, .editor:
            VStack(alignment: .leading, spacing: 8) {
                Text(interaction.method == .editor ? "Response" : "Answer")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextMuted)
                TextField(interaction.placeholder ?? "Response", text: $text, axis: interaction.method == .editor ? .vertical : .horizontal)
                    .lineLimit(interaction.method == .editor ? 5...16 : 1...1)
                    .tronField()
                    .disabled(submitting)
                    .accessibilityLabel(interaction.placeholder ?? "Response")
            }
        }
    }

    private func semanticOptionRow(_ label: String, selected: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? (destructive ? Color.tronError : Color.tronAmber) : Color.tronTextMuted)
                Text(label)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(submitting)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint((selected ? (destructive ? Color.tronError : Color.tronAmber) : Color.tronCyan).opacity(selected ? 0.20 : 0.06)).interactive(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(label)
    }

    private func resetState() {
        text = interaction.prefill ?? ""
        selectedOption = nil
        confirmValue = nil
        submissionError = nil
        submitting = false
        currentDate = Date()
    }

    private func submit() {
        guard !submitting, canSubmit, !isExpired else { return }
        let value: JSONValue?
        switch interaction.method {
        case .select: value = selectedOption.map(JSONValue.string)
        case .confirm: value = confirmValue.map(JSONValue.bool)
        case .input, .editor: value = .string(text)
        }
        respond(value: value, cancelled: false)
    }

    private func cancel() {
        guard !submitting, !isExpired else { return }
        respond(value: nil, cancelled: true)
    }

    private func respond(value: JSONValue?, cancelled: Bool) {
        submitting = true
        submissionError = nil
        Task {
            do {
                try await model.answerInteraction(interaction, sessionID: sessionID, value: value, cancelled: cancelled)
                onResolved()
                dismiss()
            } catch is CancellationError {
                submitting = false
            } catch {
                submitting = false
                submissionError = error.localizedDescription
                model.lastError = error.localizedDescription
            }
        }
    }
}
