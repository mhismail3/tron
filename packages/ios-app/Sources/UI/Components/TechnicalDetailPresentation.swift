import SwiftUI

/// Shared metadata presentation for compact technical-detail sheets. The sheet
/// owner supplies canonical values; this component owns only consistent chrome,
/// typography, spacing, and accessibility.
struct TronTechnicalMetadataItem: Identifiable, Equatable {
    let title: String
    let value: String
    let icon: String

    var id: String { title }
}

struct TronTechnicalMetadataSection: View {
    let title: String
    let items: [TronTechnicalMetadataItem]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            TronTechnicalSectionLabel(title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(accent.opacity(0.18)) }
                    metadataRow(item)
                }
            }
            .tronGlassSurface(accent: accent, tintOpacity: 0.08)
        }
    }

    private func metadataRow(_ item: TronTechnicalMetadataItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TronSpacing.sm) {
            Image(systemName: item.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16)
            Text(item.title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: TronSpacing.sm)
            Text(item.value)
                .font(TronTypography.code(size: TronTypography.sizeBody3))
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, TronSpacing.lg)
        .padding(.vertical, TronSpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.value)")
    }
}

struct TronTechnicalSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(TronTypography.sheetSectionHeader)
            .foregroundStyle(Color.tronTextMuted)
            .accessibilityAddTraits(.isHeader)
    }
}
