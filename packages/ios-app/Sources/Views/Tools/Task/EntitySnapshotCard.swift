import SwiftUI

/// Rich entity snapshot card that renders a historical EntityDetail as structured metadata.
@available(iOS 26.0, *)
struct EntitySnapshotCard: View {
    let entity: EntityDetail
    let action: String

    private let accentColor: Color = .tronSlate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            if let desc = entity.description { descriptionSection(desc) }
            metadataSection
            if !entity.subtasks.isEmpty { listSection("Subtasks", items: entity.subtasks) }
            if let notes = entity.notes { notesSection(notes) }
            if !entity.activity.isEmpty { activitySection }
            timestampsSection
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(accentColor.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TASK")
                .font(TronTypography.mono(size: 10, weight: .semibold))
                .foregroundStyle(accentColor.opacity(0.7))

            Text(entity.title)
                .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                statusBadge(entity.status)
                Spacer()
            }
        }
    }

    // MARK: - Description

    @ViewBuilder
    private func descriptionSection(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .regular))
            .foregroundStyle(.tronTextSecondary)
            .textSelection(.enabled)
    }

    // MARK: - Metadata Grid

    @ViewBuilder
    private var metadataSection: some View {
        let items = metadataItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.label) { item in
                    metadataRow(icon: item.icon, label: item.label, value: item.value)
                }
            }
        }
    }

    private struct MetadataItem {
        let icon: String
        let label: String
        let value: String
    }

    private var metadataItems: [MetadataItem] {
        var items: [MetadataItem] = []

        if let parent = entity.parentId {
            items.append(MetadataItem(icon: "arrow.turn.up.left", label: "Parent", value: parent))
        }
        if let form = entity.activeForm {
            items.append(MetadataItem(icon: "text.cursor", label: "Active form", value: form))
        }

        return items
    }

    @ViewBuilder
    private func metadataRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                .foregroundStyle(.tronTextMuted)
                .frame(width: 16)

            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .frame(width: 65, alignment: .leading)

            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - List Sections (Subtasks)

    @ViewBuilder
    private func listSection(_ title: String, items: [EntityDetail.ListItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(items.count))")
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(.tronTextMuted)

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                listItemRow(item)
            }
        }
    }

    @ViewBuilder
    private func listItemRow(_ item: EntityDetail.ListItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot(for: item.mark)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                    .foregroundStyle(item.mark == "x" ? .tronTextMuted : .tronTextPrimary)
                    .strikethrough(item.mark == "x", color: .tronTextMuted)
                    .lineLimit(2)

                Text(item.id)
                    .font(TronTypography.mono(size: 10, weight: .regular))
                    .foregroundStyle(.tronTextMuted.opacity(0.6))
            }

            Spacer()
        }
        .padding(.leading, 4)
    }

    // MARK: - Notes

    @ViewBuilder
    private func notesSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes")
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(.tronTextMuted)

            Text(text)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent activity")
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(.tronTextMuted)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entity.activity.enumerated()), id: \.offset) { index, item in
                    activityRow(item, isLast: index == entity.activity.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ item: EntityDetail.ActivityItem, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(activityColor(for: item.action))
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)

                if !isLast {
                    Rectangle()
                        .fill(Color.tronBorder.opacity(0.3))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.action.replacingOccurrences(of: "_", with: " "))
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)

                    Spacer()

                    Text(item.date)
                        .font(TronTypography.mono(size: 10, weight: .regular))
                        .foregroundStyle(.tronTextMuted.opacity(0.6))
                }

                if let detail = item.detail {
                    Text(detail)
                        .font(TronTypography.mono(size: 11, weight: .regular))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(3)
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    private func activityColor(for action: String) -> Color {
        switch action {
        case "status_changed": return .tronTeal
        case "note_added": return .tronSlate
        case "created": return .tronSuccess
        default: return .tronSlate
        }
    }

    // MARK: - Timestamps

    @ViewBuilder
    private var timestampsSection: some View {
        let hasTimestamps = entity.createdAt != nil || entity.updatedAt != nil
            || entity.startedAt != nil || entity.completedAt != nil
        if hasTimestamps {
            HStack(spacing: 12) {
                if let created = entity.createdAt {
                    timestampLabel("Created", value: DateParser.formatRelativeOrAbsolute(created))
                }
                if let updated = entity.updatedAt {
                    timestampLabel("Updated", value: DateParser.formatRelativeOrAbsolute(updated))
                }
                if let started = entity.startedAt {
                    timestampLabel("Started", value: DateParser.formatRelativeOrAbsolute(started))
                }
                if let completed = entity.completedAt {
                    timestampLabel("Done", value: DateParser.formatRelativeOrAbsolute(completed))
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func timestampLabel(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(TronTypography.mono(size: 9, weight: .medium))
                .foregroundStyle(.tronTextMuted.opacity(0.6))
            Text(value)
                .font(TronTypography.mono(size: 10, weight: .regular))
                .foregroundStyle(.tronTextMuted)
        }
    }

    // MARK: - Badge Helpers

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let color = TaskFormatting.statusColor(status)
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.replacingOccurrences(of: "_", with: " "))
                .font(TronTypography.mono(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(color.opacity(0.2)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private func statusDot(for mark: String) -> some View {
        let color: Color = switch mark {
        case "x": .tronSuccess
        case ">": .tronTeal
        case "-": .tronError
        case "?": .tronAmber
        default: .tronSlate.opacity(0.5)
        }

        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .padding(.top, 5)
    }
}
