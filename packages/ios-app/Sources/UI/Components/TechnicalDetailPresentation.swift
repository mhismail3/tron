import SwiftUI

struct TronTechnicalMetadataItem: Identifiable, Equatable {
    let title: String
    let value: String
    let icon: String

    var id: String { title }
}

struct TronMetadataTableRow: Identifiable {
    let id: String
    let title: String
    let value: String
    var icon: String?
    var type: String?

    init(id: String, title: String, value: String, icon: String? = nil, type: String? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.icon = icon
        self.type = type
    }
}

enum TronMetadataValueStyle {
    case wraps
    case preview
}

struct TronMetadataTable: View {
    var title: String?
    let accent: Color
    let rows: [TronMetadataTableRow]
    var valueStyle: TronMetadataValueStyle = .wraps
    var onSelect: ((TronMetadataTableRow) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            if let title { TronTechnicalSectionLabel(title).containerValue(\.tronSettingsSection, false) }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(accent.opacity(0.18)) }
                    rowContent(row)
                }
            }
            .tronGlassSurface(accent: accent, tintOpacity: 0.08)
        }
    }

    @ViewBuilder
    private func rowContent(_ row: TronMetadataTableRow) -> some View {
        if let onSelect {
            Button { onSelect(row) } label: { rowLayout(row) }
                .buttonStyle(.plain)
                .accessibilityLabel([row.title, row.type, row.value].compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint("Opens the complete value")
        } else {
            rowLayout(row)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.title), \(row.value)")
        }
    }

    private func rowLayout(_ row: TronMetadataTableRow) -> some View {
        let stacks = dynamicTypeSize.isAccessibilitySize && row.icon == nil
        let layout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TronSpacing.md))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TronSpacing.sm))
        return layout {
            if let icon = row.icon {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 16)
            }
            Text(row.title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let type = row.type {
                Text(type)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if !stacks { Spacer(minLength: TronSpacing.sm) }
            value(row, stacks: stacks)
        }
        .padding(.horizontal, TronSpacing.lg)
        .padding(.vertical, TronSpacing.md)
    }

    @ViewBuilder
    private func value(_ row: TronMetadataTableRow, stacks: Bool) -> some View {
        switch valueStyle {
        case .wraps:
            Text(row.value)
                .font(TronTypography.code(size: TronTypography.sizeBody3))
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(stacks ? .leading : .trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .preview:
            Text(row.value)
                .font(TronTypography.code(size: TronTypography.sizeBody3))
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(stacks ? 3 : 1)
                .truncationMode(.head)
                .multilineTextAlignment(stacks ? .leading : .trailing)
        }
    }
}

struct TronTechnicalMetadataSection: View {
    let title: String
    let items: [TronTechnicalMetadataItem]
    let accent: Color

    var body: some View {
        TronMetadataTable(
            title: title,
            accent: accent,
            rows: items.map {
                TronMetadataTableRow(id: $0.id, title: $0.title, value: $0.value, icon: $0.icon)
            }
        )
    }
}

struct TronTechnicalSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .tronSectionHeading()
            .foregroundStyle(Color.tronTextMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

struct TronSheetInfoButton: View {
    let accessibilityLabel: String
    var accent: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle").font(TronTypography.buttonSM).tronToolbarAction(accent: accent)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
