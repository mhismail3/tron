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
    @PresentationState private var showingTechnicalDetails = false
    private var presentation: ChangeReviewPresentation { ChangeReviewPresentation(review) }

    init(review: ChangeReview, submitting: Bool = false, secret: Binding<String>? = nil, failure: String? = nil,
         close: (() -> Void)? = nil, approve: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.review = review; self.submitting = submitting; self.secret = secret; self.failure = failure; self.close = close
        self.approve = approve; self.cancel = cancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: TronSpacing.section) {
                    header
                    ForEach(Array(presentation.items.enumerated()), id: \.offset) { _, item in
                        TronSettingsGroup(item.label) {
                            value("Before", item.before)
                            TronSettingsDivider(leadingPadding: TronSettingsLayoutPolicy.rowHorizontalPadding)
                            value("After", item.after)
                        }
                        .tronSettingsCaption(item.note)
                    }
                    if let secret {
                        TronSettingsGroup("API key") {
                            Text(verbatim: "Paste API key")
                                .hidden()
                                .modifier(ReviewRowInsets())
                                .overlay {
                                    SecureField("Paste API key", text: secret)
                                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .tronTextEntryDone()
                                        .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                                        .frame(maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                        .accessibilityIdentifier("change-review-secret")
                                }
                        }
                        .tronSettingsCaption("Sent once to your Mac and stored in its Keychain. It is never shown again.")
                    }
                    TronGlassCard {
                        Button { showingTechnicalDetails = true } label: {
                            TronSettingsRow(icon: "info.circle", title: "Technical details",
                                            subtitle: "Exact values, scope and digest") {
                                Image(systemName: "chevron.right")
                                    .font(TronTypography.buttonSM)
                                    .foregroundStyle(Color.tronTextMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("change-review-technical-details")
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
        .tronManagedSheet(isPresented: $showingTechnicalDetails, identity: "change-review.technical.\(review.digest)") {
            TronDocumentSheet(title: "Technical details") {
                ScrollView {
                    TronSettingsSections(alignment: .leading, spacing: TronSpacing.section) {
                        TronTechnicalMetadataSection(title: "Change", items: presentation.change, accent: .tronPrimary)
                        ForEach(presentation.technical) { section in
                            TronTechnicalMetadataSection(title: section.title, items: section.facts, accent: .tronPrimary)
                            if let exact = section.exact {
                                TronSettingsGroup("\(section.title) exact values") { TronSettingsCodeRow(text: exact) }
                            }
                        }
                    }
                    .padding(18)
                    .accessibilityIdentifier("change-review-technical")
                }
                .tronScrollEdgeChrome()
            }
            .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: presentation.title)
                .font(TronTypography.summaryHeadline)
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = presentation.reason {
                Text(verbatim: reason)
                    .font(TronTypography.settingsRowSubtext)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronPrimary, tintOpacity: 0.14)
        .accessibilityElement(children: .combine)
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
