import SwiftUI

/// Welcome is the wizard's entry step. The shell owns the icon, title,
/// progress pill, and both action buttons (primary "Get started", link
/// "I already have Tron running"); this view contributes only the
/// description text plus a contextual banner if an existing install
/// has already been detected on disk.
///
/// Layout note: when no banner is showing, the description is centered
/// both vertically and horizontally so the welcome screen reads as a
/// proper hero moment rather than a leading paragraph adrift in white
/// space. The instant an existing install is detected, we revert to a
/// top-leading layout so the description and banner stack as a normal
/// reading column.
struct WelcomeStep: View {
    @Bindable var state: WizardState

    private let copy = "Tron is an agent that lives on your Mac. You talk to Tron from your iPhone."

    var body: some View {
        if case .installed(let version) = state.existingInstallStatus {
            VStack(alignment: .leading, spacing: 16) {
                descriptionText
                existingInstallBanner(version: version)
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                descriptionText
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var descriptionText: some View {
        Text(copy)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func existingInstallBanner(version: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.tronSuccess)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text("Existing Tron install detected")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.tronEmerald)
                if let version {
                    Text("Version \(version) — onboarding will skip the install step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.tronEmerald.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}
