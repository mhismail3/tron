import SwiftUI

/// Shared metadata presentation for technical-detail and tool-detail sheets. The
/// sheet owner supplies canonical values; this component owns only consistent
/// chrome, typography, spacing, and accessibility.
struct TronTechnicalMetadataItem: Identifiable, Equatable {
    let title: String
    let value: String
    let icon: String

    var id: String { title }
}

/// One row of a metadata/value table. Icon-led tables (runtime facts, tool
/// metadata) use `icon`; the generalized JSON tables qualify the title with
/// `type` instead, because a value's JSON type is what the reader needs there.
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

/// How a table renders its trailing value. Canonical tables wrap and allow
/// selection; a preview table keeps one bounded line per row so a long JSON
/// value cannot displace its siblings.
enum TronMetadataValueStyle {
    case wraps
    case preview
}

/// The standard metadata/value table: an optional uppercase section label, one
/// divided glass card, and one row geometry for every table in the app.
struct TronMetadataTable: View {
    var title: String?
    let accent: Color
    let rows: [TronMetadataTableRow]
    var valueStyle: TronMetadataValueStyle = .wraps
    /// When set, each row is a progressive target for its own detail value
    /// instead of a static label/value pair.
    var onSelect: ((TronMetadataTableRow) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            if let title { TronTechnicalSectionLabel(title) }
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
            // Keep the button element: overriding the label must not drop the
            // trait that tells VoiceOver the row is actionable.
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
        // A qualified title plus a value needs its own line at accessibility
        // sizes; an icon-led table keeps the standard single row.
        let stacks = dynamicTypeSize.isAccessibilitySize && row.type != nil
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
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .preview:
            // Hug the value instead of claiming the row's slack: a preview must
            // never squeeze the title into wrapping.
            Text(row.value)
                .font(TronTypography.code(size: TronTypography.sizeBody3))
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(stacks ? 3 : 1)
                .truncationMode(.head)
                .multilineTextAlignment(stacks ? .leading : .trailing)
        }
    }
}

/// The icon-led form of the standard table, used by every technical-detail
/// sheet and the server info sheet.
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
            .font(TronTypography.sheetSectionHeader)
            .foregroundStyle(Color.tronTextMuted)
            .accessibilityAddTraits(.isHeader)
    }
}
