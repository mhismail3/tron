import SwiftUI
import UIKit

/// Shared building blocks for the first-run onboarding sheet.
///
/// The dashboard always remains mounted underneath this sheet. Onboarding is
/// a short paged overlay: two lightweight orientation pages, then the pairing
/// form that performs the actual connection.
@available(iOS 26.0, *)
struct OnboardingTopBar: View {
    let step: OnboardingState.Step

    var body: some View {
        HStack {
            Text(step.counterText)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(
                    .regular.tint(Color.tronEmerald.opacity(0.18)),
                    in: Capsule()
                )
                .accessibilityLabel("Step \(step.number) of \(OnboardingState.Step.totalCount)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, TronSpacing.xl)
        .padding(.top, TronSpacing.lg)
        .padding(.bottom, TronSpacing.sm)
    }
}

@available(iOS 26.0, *)
struct OnboardingPage<Content: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let content: Content

    init(
        systemImage: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                header
                content
            }
            .padding(.horizontal, TronSpacing.xl)
            .padding(.bottom, TronSpacing.xl)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            HStack(alignment: .center, spacing: TronSpacing.md) {
                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald)
                    .frame(width: 32, height: 32)

                Text(title)
                    .font(TronTypography.largeTitle)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            Text(subtitle)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(Color.tronTextSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
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

@available(iOS 26.0, *)
struct OnboardingSwipeHint: View {
    let title: String

    var body: some View {
        HStack(spacing: TronSpacing.sm) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            Image(systemName: "arrow.left")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
        }
        .foregroundStyle(Color.tronEmerald)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(0.14)),
            in: Capsule()
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

@available(iOS 26.0, *)
struct OnboardingPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Color.tronBackground)
                }
                if let systemImage, !isLoading {
                    Image(systemName: systemImage)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                }
                Text(title)
                    .font(TronTypography.button)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(isEnabled ? Color.tronBackground : Color.tronTextMuted)
            .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerLG, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint((isEnabled ? Color.tronEmerald : Color.tronOverlay(0.16)).opacity(isEnabled ? 0.72 : 0.28)).interactive(),
            in: RoundedRectangle(cornerRadius: TronSpacing.cornerLG, style: .continuous)
        )
        .disabled(!isEnabled || isLoading)
    }
}

@available(iOS 26.0, *)
struct OnboardingIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.18)).interactive(), in: Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}
