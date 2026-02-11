import SwiftUI

// MARK: - Section Card (Legacy)

/// Container for grouped content with a header label
struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
            }
            .foregroundStyle(accentColor.opacity(0.8))
            .padding(.leading, 4)

            // Content
            VStack(spacing: 0) {
                content()
            }
            .padding(12)
            .background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accentColor.opacity(0.15), lineWidth: 1)
            )
        }
    }
}

// MARK: - Glass Section Card (iOS 26+)

/// Container with glass effect for iOS 26+
@available(iOS 26.0, *)
struct GlassSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
            }
            .foregroundStyle(accentColor.opacity(0.8))
            .padding(.leading, 4)

            // Content with glass effect
            VStack(spacing: 0) {
                content()
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(accentColor.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
