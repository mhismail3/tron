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
                    if let cancel {
                        Button("Cancel", action: cancel).buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronAmber))
                            .accessibilityIdentifier("change-review-cancel")
                    }
                    Spacer(minLength: 8)
                    if let undo { Button("Undo", action: undo).buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronAmber)) }
                    if let approve {
                        Button(action: approve) {
                            if submitting { ProgressView() } else { Text("Approve") }
                        }.buttonStyle(TronActionButtonStyle(role: .primary, accent: .tronAmber))
                            .accessibilityIdentifier("change-review-approve")
                    }
                }.disabled(submitting)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.08)
        // A containing element keeps each action's own identifier.
        .accessibilityElement(children: .contain)
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

/// The one sheet that presents an exact review. Its owner answers Approve with the
/// review's digest through the typed RPC; Cancel or dismissal applies nothing.
struct ChangeReviewSheet: View {
    let review: ChangeReview
    var submitting = false
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                ChangeReviewCard(review: review, submitting: submitting, approve: approve, cancel: cancel)
                    .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("Review change")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tronTopBlur(.sheet)
    }
}

/// One exact review waiting for the maintainer's tap, and the typed owner call
/// that answers it with the review's digest. The call reports its own outcome.
struct PendingChangeReview: Identifiable {
    let review: ChangeReview
    let confirm: @MainActor (String) async -> Void
    var id: String { review.digest }
}

extension View {
    /// Presents a pending review in the shared sheet. Approve retires the sheet and
    /// answers once; Cancel or dismissal leaves nothing applied.
    func changeReviewSheet(_ pending: Binding<PendingChangeReview?>, identity: String) -> some View {
        tronManagedSheet(item: pending, identity: { "\(identity).\($0.id)" }) { item in
            ChangeReviewSheet(review: item.review, approve: {
                guard pending.wrappedValue?.id == item.id else { return }
                pending.wrappedValue = nil
                Task { @MainActor in await item.confirm(item.review.digest) }
            }, cancel: { pending.wrappedValue = nil })
        }
    }
}
