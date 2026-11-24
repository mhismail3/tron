import SwiftUI
import TronMobileCore

struct ChangeReviewSheet: View {
    let review: ChangeReview
    let submitting: Bool
    let secret: Binding<String>?
    let failure: String?
    let close: (() -> Void)?
    let approve: () -> Void
    let cancel: () -> Void

    init(review: ChangeReview, submitting: Bool = false, secret: Binding<String>? = nil, failure: String? = nil,
         close: (() -> Void)? = nil, approve: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.review = review; self.submitting = submitting; self.secret = secret; self.failure = failure; self.close = close
        self.approve = approve; self.cancel = cancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: TronSpacing.section) {
                    TronSettingsGroup(nil) {
                        TronSettingsRow(icon: "checkmark.shield", title: review.title, subtitle: review.reason, subtitleLineLimit: nil)
                    }
                    ForEach(Array(review.items.enumerated()), id: \.offset) { _, item in
                        TronSettingsGroup(item.label) {
                            value("Before", item.before)
                            TronSettingsDivider()
                            value("After", item.after)
                        }
                        .tronSettingsCaption(item.detail)
                        if let exact = item.exact {
                            TronSettingsGroup("Exact values") { TronSettingsCodeRow(text: exact) }
                        }
                    }
                    if let secret {
                        TronSettingsGroup("API key") {
                            Text(verbatim: "Paste API key")
                                .hidden()
                                .frame(maxWidth: .infinity)
                                .overlay {
                                    SecureField("Paste API key", text: secret)
                                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .tronTextEntryDone()
                                }
                                .modifier(ReviewRowInsets())
                                .accessibilityIdentifier("change-review-secret")
                        }
                        .tronSettingsCaption("Sent once to your Mac and stored in its Keychain. It is never shown again.")
                    }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronError)
                            .accessibilityLabel("Could not submit: \(failure)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("change-review-card")
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let close {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: close) {
                            Image(systemName: "xmark").font(TronTypography.buttonSM)
                        }
                        .tronToolbarAction(role: .neutral)
                        .disabled(submitting)
                        .accessibilityLabel("Close review without deciding")
                    }
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Review change", accent: .tronPrimary)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(role: .destructive, action: cancel) {
                        Image(systemName: "hand.raised.fill").font(TronTypography.buttonSM)
                    }
                    .tronToolbarAction(role: .destructive)
                    .disabled(submitting)
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("change-review-cancel")
                    Button(action: approve) {
                        if submitting {
                            TronPulseLoadingIndicator(accent: .tronPrimary, size: 14)
                        } else {
                            Image(systemName: "checkmark").font(TronTypography.buttonSM)
                        }
                    }
                    .tronToolbarAction(accent: .tronPrimary)
                    .disabled(submitting || (secret?.wrappedValue.isEmpty ?? false))
                    .accessibilityLabel("Approve")
                    .accessibilityIdentifier("change-review-approve")
                }
            }
        }
        .tronTopBlur(.sheet)
        .interactiveDismissDisabled(close != nil || submitting)
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(TronTypography.settingsRowSubtext)
                .foregroundStyle(Color.tronTextSecondary)
            Text(verbatim: text)
                .font(TronTypography.body)
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(ReviewRowInsets())
    }
}

private struct ReviewRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
            .padding(.vertical, TronSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
