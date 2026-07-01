import SwiftUI

struct CredentialEntryCard: View {
    let title: String
    @Binding var label: String
    @Binding var secret: String
    let isSaving: Bool
    let actionTitle: String
    let onSave: () -> Void

    var body: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)

                setupField("Label", text: $label, secure: false)
                setupField("API key", text: $secret, secure: true)

                SetupActionButton(
                    title: isSaving ? "Saving" : actionTitle,
                    systemImage: "key",
                    action: onSave
                )
                .disabled(isSaving)
            }
        }
    }
}

struct CompactApiKeyCard: View {
    let title: String
    let placeholder: String
    let existingSummary: OnboardingCredentialSummary?
    let save: (String) async throws -> AuthSnapshot
    let onSaved: (AuthSnapshot) -> Void

    @State private var key = ""
    @State private var isSaving = false
    @State private var status: String?

    var body: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                HStack(alignment: .top, spacing: TronSpacing.md) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let existingSummary {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(existingSummary.title)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(existingSummary.isExpired ? Color.tronWarning : Color.tronEmerald)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(1)

                            Text(keyPreviewText(for: existingSummary))
                                .font(TronTypography.code(size: TronTypography.sizeCaption))
                                .foregroundStyle(Color.tronTextSecondary)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 190, alignment: .trailing)
                    }
                }

                setupField(placeholder, text: $key, secure: true)

                SetupActionButton(
                    title: isSaving ? "Saving" : (existingSummary?.kind == .apiKey ? "Replace key" : "Save key"),
                    systemImage: "key",
                    action: saveKey
                )
                .disabled(isSaving)

                if let status {
                    SetupStatusText(status)
                }
            }
        }
    }

    private func keyPreviewText(for summary: OnboardingCredentialSummary) -> String {
        summary.keyPreview ?? summary.detail
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter a key first."
            return
        }

        isSaving = true
        status = nil
        Task {
            do {
                let authState = try await save(trimmed)
                onSaved(authState)
                key = ""
                status = nil
            } catch {
                status = "Failed"
            }
            isSaving = false
        }
    }
}

struct ExistingCredentialCard: View {
    let summary: OnboardingCredentialSummary

    var body: some View {
        OnboardingGlassCard {
            if summary.kind == .oauth {
                oauthRow
            } else {
                defaultRow
            }
        }
    }

    private var oauthRow: some View {
        HStack(alignment: .center, spacing: TronSpacing.md) {
            statusIcon

            Text(oauthPrimaryText)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: TronSpacing.sm)

            Text(oauthStatusText)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(summary.isExpired ? Color.tronWarning : Color.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultRow: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            statusIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(summary.detail)
                    .font(TronTypography.code(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    private var statusIcon: some View {
        Image(systemName: summary.isExpired ? "exclamationmark.triangle" : "checkmark.seal")
            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
            .foregroundStyle(summary.isExpired ? Color.tronWarning : Color.tronEmerald)
            .frame(width: 30, height: 30)
    }

    private var oauthPrimaryText: String {
        summary.credentialLabel ?? summary.detail
    }

    private var oauthStatusText: String {
        summary.isExpired ? summary.title : "Logged in with OAuth"
    }
}

struct SetupActionButton: View {
    let title: String
    let systemImage: String
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(Color.tronEmerald)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(0.16)).interactive(),
            in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
        )
    }
}

struct SetupStatusText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
func setupField(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
    Group {
        if secure {
            SecureField(placeholder, text: text)
        } else {
            TextField(placeholder, text: text)
        }
    }
    .font(TronTypography.code(size: TronTypography.sizeBodySM))
    .foregroundStyle(Color.tronTextPrimary)
    .autocorrectionDisabled(true)
    .textInputAutocapitalization(.never)
    .padding(.vertical, 11)
    .padding(.horizontal, TronSpacing.md)
    .glassEffect(
        .regular.tint(Color.tronOverlay(0.16)),
        in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
    )
}
