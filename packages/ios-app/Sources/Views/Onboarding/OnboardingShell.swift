import SwiftUI

/// Shared chrome for the onboarding sheet.
///
/// The sheet is intentionally compact: one header, one scrollable content
/// area, and a footer pinned to the bottom. It can grow to the large
/// detent for keyboard entry but starts as a medium overlay above the
/// dashboard.
///
/// Layout:
///
///   ┌──────────────────────────────────────────────────┐
///   │  [<- back]                                       │  ← compact bar
///   │                                                  │
///   │  Title (largeTitle, primary)                     │
///   │  Subtitle (body, secondary, optional)            │
///   │                                                  │
///   │  ─── content slot ──────────────────────────     │  ← pushed up;
///   │                                                  │     ScrollView
///   │                                                  │     so long copy
///   │                                                  │     never clips
///   │  ─── footer slot (primary + secondary CTA) ──    │  ← pinned bottom
///   └──────────────────────────────────────────────────┘
///
/// **Why a shell + slots** (vs a per-step bespoke layout): keeps the
/// progressive-disclosure invariants in one file (back button is always
/// top-left, primary action is always bottom). Designers can tweak the
/// spec once and every step inherits the change.
struct OnboardingShell<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let showsBackButton: Bool
    let onBack: (() -> Void)?
    let content: Content
    let footer: Footer

    init(
        title: String,
        subtitle: String? = nil,
        showsBackButton: Bool = true,
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsBackButton = showsBackButton
        self.onBack = onBack
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBackButton, onBack != nil {
                topBar
            }

            ScrollView(showsIndicators: false) {
                bodyStack
                    .padding(.horizontal, TronSpacing.xl)
                    .padding(.top, showsBackButton ? TronSpacing.md : TronSpacing.xl)
                    .padding(.bottom, TronSpacing.lg)
                    .frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)

            footer
                .padding(.horizontal, TronSpacing.xl)
                .padding(.top, TronSpacing.md)
                .padding(.bottom, TronSpacing.lg)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
        }
        .tronScreenBackground()
    }

    @ViewBuilder
    private var bodyStack: some View {
        VStack(alignment: .leading, spacing: TronSpacing.lg) {
            headerBlock
            content
        }
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        HStack {
            if showsBackButton, let onBack = onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(TronTypography.buttonSM)
                    }
                    .foregroundStyle(Color.tronTextSecondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
                .accessibilityLabel("Back to previous step")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TronSpacing.xl)
        .padding(.top, TronSpacing.md)
        .frame(height: 34)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Text(title)
                .font(TronTypography.largeTitle)
                .foregroundStyle(Color.tronTextPrimary)
                .accessibilityAddTraits(.isHeader)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Reusable button styles for onboarding footers

/// Big block primary button — the canonical "Continue / Connect / Allow"
/// affordance at the bottom of every step.
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
                if let systemImage = systemImage, !isLoading {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(TronTypography.button)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(Color.tronBackground)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEnabled ? Color.tronEmerald : Color.tronEmerald.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }
}

/// Subtle secondary button rendered below the primary — "Skip", "Open
/// Tron download", "I already have Tron running", etc.
struct OnboardingSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                }
                Text(title)
                    .font(TronTypography.buttonSM)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Color.tronTextSecondary)
        }
        .buttonStyle(.plain)
    }
}
