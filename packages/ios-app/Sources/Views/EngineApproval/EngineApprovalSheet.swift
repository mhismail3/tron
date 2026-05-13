import SwiftUI

// MARK: - EngineApproval Sheet

/// Sheet for resolving engine-owned approval records.
/// Shows action, reason, risk level badge, approve/deny buttons, and optional note input.
@available(iOS 26.0, *)
struct EngineApprovalSheet: View {
    let capabilityData: EngineApprovalData
    let onSubmit: (EngineApprovalUserDecision, String?) -> Void
    let onDismiss: () -> Void
    var readOnly: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var noteText = ""

    private var isDecided: Bool {
        capabilityData.status == .approved || capabilityData.status == .denied || capabilityData.status == .failed
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    // Risk level header
                    riskHeader

                    // Action section
                    detailSection(title: "Action", content: capabilityData.params.action)

                    // Reason section
                    detailSection(title: "Reason", content: capabilityData.params.reason)

                    // Note section (read-only for decided, editable for pending)
                    if readOnly {
                        if let note = capabilityData.note, !note.isEmpty {
                            detailSection(title: "Note", content: note)
                        }
                    } else {
                        noteInput
                    }

                    // Action buttons (only for pending)
                    if !readOnly {
                        actionButtons
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(readOnly ? decisionTitle : "Confirm Action")
                        .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !readOnly {
                        Button {
                            dismiss()
                            onDismiss()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .medium))
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accentColor)
        .onAppear {
            noteText = capabilityData.note ?? ""
        }
    }

    // MARK: - Risk Header

    private var riskHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: riskIcon)
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(riskColor)

            Text(riskLabel)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(riskColor)

            Spacer()

            if isDecided {
                decisionBadge
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(riskColor.opacity(0.2)),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var decisionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: capabilityData.decision == .approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            Text(capabilityData.decision?.rawValue ?? "")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
        }
        .foregroundStyle(capabilityData.decision == .approved ? Color.tronSuccess : Color.tronError)
    }

    // MARK: - Detail Section

    private func detailSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)

            Text(inlineMarkdown(from: content, size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
    }

    // MARK: - Note Input

    private var noteInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note (optional)")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)

            TextField("Add a note for the agent...", text: $noteText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TronTypography.messageBody)
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(3...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(accentColor.opacity(noteText.isEmpty ? 0.06 : 0.15)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Deny button
            Button {
                let note = noteText.isEmpty ? nil : noteText
                onSubmit(.denied, note)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    Text("Deny")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                .foregroundStyle(.tronError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(Color.tronError.opacity(0.2)).interactive(),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
            }
            .buttonStyle(.plain)

            // Approve button
            Button {
                let note = noteText.isEmpty ? nil : noteText
                onSubmit(.approved, note)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    Text("Approve")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                .foregroundStyle(.tronSuccess)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(Color.tronSuccess.opacity(0.2)).interactive(),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - Computed Properties

    private var accentColor: Color {
        switch capabilityData.status {
        case .pending: return .tronAmber
        case .approved: return .tronSuccess
        case .denied, .failed: return .tronError
        }
    }

    private var decisionTitle: String {
        switch capabilityData.decision {
        case .approved: return "Approved"
        case .denied: return "Denied"
        case nil: return capabilityData.status == .failed ? "Failed" : "Approval"
        }
    }

    private var riskIcon: String {
        switch capabilityData.params.riskLevel {
        case .low: return "shield"
        case .medium: return "shield.lefthalf.filled"
        case .high: return "exclamationmark.shield.fill"
        }
    }

    private var riskLabel: String {
        switch capabilityData.params.riskLevel {
        case .low: return "Low Risk"
        case .medium: return "Medium Risk"
        case .high: return "High Risk"
        }
    }

    private var riskColor: Color {
        switch capabilityData.params.riskLevel {
        case .low: return .tronEmerald
        case .medium: return .tronAmber
        case .high: return .tronError
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("Pending - Low Risk") {
    EngineApprovalSheet(
        capabilityData: EngineApprovalData(
            invocationId: "call_1",
            params: EngineApprovalParams(
                action: "Install ffmpeg via brew",
                reason: "The video processing task requires ffmpeg for format conversion.",
                riskLevel: .low
            ),
            status: .pending
        ),
        onSubmit: { _, _ in },
        onDismiss: { }
    )
}

@available(iOS 26.0, *)
#Preview("Pending - High Risk") {
    EngineApprovalSheet(
        capabilityData: EngineApprovalData(
            invocationId: "call_2",
            params: EngineApprovalParams(
                action: "Deploy v2.0 to production",
                reason: "All tests pass and the release branch is ready. This will affect live users.",
                riskLevel: .high
            ),
            status: .pending
        ),
        onSubmit: { _, _ in },
        onDismiss: { }
    )
}

@available(iOS 26.0, *)
#Preview("Approved - Read Only") {
    EngineApprovalSheet(
        capabilityData: EngineApprovalData(
            invocationId: "call_3",
            params: EngineApprovalParams(
                action: "Install ffmpeg via brew",
                reason: "Needed for video processing",
                riskLevel: .low
            ),
            status: .approved,
            decision: .approved,
            note: "Go ahead"
        ),
        onSubmit: { _, _ in },
        onDismiss: { },
        readOnly: true
    )
}
#endif
