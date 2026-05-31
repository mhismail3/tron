import SwiftUI
import UIKit

/// Shared building blocks for the first-run onboarding sheet.
///
/// The dashboard always remains mounted underneath this sheet. Onboarding is
/// a short paged overlay: three lightweight preparation pages, then
/// the pairing form that performs the actual connection.

@available(iOS 26.0, *)
struct OnboardingPage<Content: View>: View {
    let subtitle: String
    let content: Content

    init(
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .padding(.horizontal, TronSpacing.xlarge)
            .padding(.top, TronSpacing.lg)
            .padding(.bottom, 126)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

@available(iOS 26.0, *)
struct OnboardingGlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(TronSpacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                .regular.tint(Color.tronEmerald.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: TronSpacing.cornerLG, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TronSpacing.cornerLG, style: .continuous)
                    .stroke(Color.tronEmerald.opacity(0.22), lineWidth: 1)
            )
    }
}

@available(iOS 26.0, *)
struct OnboardingInfoRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: systemImage)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
