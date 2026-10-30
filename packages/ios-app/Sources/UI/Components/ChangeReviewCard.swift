import SwiftUI
import TronMobileCore

/// The shared plaintext before/after card. It renders the exact Gateway projection;
/// generic forms never supply its actions or grant authority.
struct ChangeReviewCard: View {
    let title: String
    let reason: String?
    let items: [ChangeReview.Item]
    var submitting: Bool
    var approve: (() -> Void)?
    var cancel: (() -> Void)?
    var undo: (() -> Void)?

    init(review: ChangeReview, submitting: Bool = false, approve: (() -> Void)? = nil,
         cancel: (() -> Void)? = nil, undo: (() -> Void)? = nil) {
        title = review.title; reason = review.reason; items = review.items
        self.submitting = submitting; self.approve = approve; self.cancel = cancel; self.undo = undo
    }

    /// Read-only history uses its server-formatted values, never an invented
    /// confirmation digest or inverse. Actions stay with the typed receipt owner.
    init(title: String, reason: String?, before: String, after: String) {
        self.title = title; self.reason = reason
        items = [.init(label: title, before: before, after: after)]
        submitting = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: title)
                .font(TronTypography.body.weight(.semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason, !reason.isEmpty {
                Text(verbatim: reason)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: item.label).font(TronTypography.body.weight(.semibold))
                    value("Before", item.before)
                    value("After", item.after)
                    if let detail = item.detail {
                        Text(verbatim: detail).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let exact = item.exact {
                        DisclosureGroup("Exact values") {
                            Text(verbatim: exact).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if approve != nil || cancel != nil || undo != nil {
                HStack {
                    if let cancel { Button("Cancel", action: cancel).buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronAmber)) }
                    Spacer(minLength: 8)
                    if let undo { Button("Undo", action: undo).buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronAmber)) }
                    if let approve {
                        Button(action: approve) {
                            if submitting { ProgressView() } else { Text("Approve") }
                        }.buttonStyle(TronActionButtonStyle(role: .primary, accent: .tronAmber))
                    }
                }.disabled(submitting)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.08)
        .accessibilityIdentifier("change-review-card")
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted)
            Text(verbatim: text).font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
