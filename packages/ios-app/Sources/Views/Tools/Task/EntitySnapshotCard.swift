import SwiftUI

/// Rich entity snapshot card that renders a historical EntityDetail as structured metadata.
/// Used in TaskDetailSheet for create/update/get/delete/log_time actions.
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
            if !entity.tasks.isEmpty { listSection("Tasks", items: entity.tasks) }
            if !entity.blockedBy.isEmpty || !entity.blocks.isEmpty { dependenciesSection }
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
            // Entity type label
            Text(entity.entityType.rawValue.uppercased())
                .font(TronTypography.mono(size: 10, weight: .semibold))
                .foregroundStyle(accentColor.opacity(0.7))

            // Title
            Text(entity.title)
                .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)

            // Status + Priority badges
            HStack(spacing: 8) {
                statusBadge(entity.status)

                if let priority = entity.priority, priority != "medium" {
                    priorityBadge(priority)
                }

                // Progress for projects
                if let completed = entity.completedTaskCount, let total = entity.taskCount {
                    progressBadge(completed: completed, total: total)
                }

                // Counts for areas
                if entity.entityType == .area {
                    if let pc = entity.projectCount {
                        countBadge(count: pc, label: "project")
                    }
                    if let tc = entity.taskCount, let ac = entity.activeTaskCount {
                        countBadge(count: tc, label: "task", detail: "\(ac) active")
                    }
                }

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
                    metadataRow(icon: item.icon, label: item.label, value: item.value, valueColor: item.color)
                }
            }
        }
    }

    private struct MetadataItem {
        let icon: String
        let label: String
        let value: String
        let color: Color?
    }

    private var metadataItems: [MetadataItem] {
        var items: [MetadataItem] = []

        if let proj = entity.projectName {
            items.append(MetadataItem(icon: "folder", label: "Project", value: proj, color: nil))
        }
        if let area = entity.areaName {
            items.append(MetadataItem(icon: "square.grid.2x2", label: "Area", value: area, color: nil))
        }
        if let due = entity.dueDate {
            items.append(MetadataItem(icon: "calendar", label: "Due", value: due, color: .tronWarning))
        }
        if let deferred = entity.deferredUntil {
            items.append(MetadataItem(icon: "clock.arrow.2.circlepath", label: "Deferred", value: deferred, color: nil))
        }
        if let est = entity.estimatedMinutes {
            let actual = entity.actualMinutes ?? 0
            items.append(MetadataItem(icon: "clock", label: "Time", value: "\(actual)/\(est)min", color: nil))
        }
        if !entity.tags.isEmpty {
            items.append(MetadataItem(icon: "tag", label: "Tags", value: entity.tags.joined(separator: ", "), color: nil))
        }
        if let source = entity.source {
            items.append(MetadataItem(icon: "person", label: "Source", value: source, color: nil))
        }
        if let parent = entity.parentId {
            items.append(MetadataItem(icon: "arrow.turn.up.left", label: "Parent", value: parent, color: nil))
        }
        if let form = entity.activeForm {
            items.append(MetadataItem(icon: "text.cursor", label: "Active form", value: form, color: nil))
        }

        return items
    }

    @ViewBuilder
    private func metadataRow(icon: String, label: String, value: String, valueColor: Color?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.tronTextMuted)
                .frame(width: 16)

            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .frame(width: 65, alignment: .leading)

            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                .foregroundStyle(valueColor ?? .tronTextSecondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - List Sections (Subtasks / Tasks)

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
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(item.mark == "x" ? .tronTextMuted : .tronTextPrimary)
                        .strikethrough(item.mark == "x", color: .tronTextMuted)
                        .lineLimit(2)

                    if let extra = item.extra {
                        Text(extra)
                            .font(TronTypography.mono(size: 10, weight: .medium))
                            .foregroundStyle(priorityColor(for: extra))
                    }
                }

                Text(item.id)
                    .font(TronTypography.mono(size: 10, weight: .regular))
                    .foregroundStyle(.tronTextMuted.opacity(0.6))
            }

            Spacer()
        }
        .padding(.leading, 4)
    }

    // MARK: - Dependencies

    @ViewBuilder
    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entity.blockedBy.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 10))
                        .foregroundStyle(.tronWarning)
                    Text("Blocked by:")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                    Text(entity.blockedBy.joined(separator: ", "))
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(.tronWarning)
                }
            }

            if !entity.blocks.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 10))
                        .foregroundStyle(.tronTextMuted)
                    Text("Blocks:")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                    Text(entity.blocks.joined(separator: ", "))
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(.tronTextSecondary)
                }
            }
        }
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
            // Timeline track: dot + connector line
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

            // Content
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
        case "time_logged": return .tronAmber
        case "note_added": return .tronSlate
        case "created": return .tronSuccess
        case "priority_changed": return .orange
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
                    timestampLabel("Created", value: formatTimestamp(created))
                }
                if let updated = entity.updatedAt {
                    timestampLabel("Updated", value: formatTimestamp(updated))
                }
                if let started = entity.startedAt {
                    timestampLabel("Started", value: formatTimestamp(started))
                }
                if let completed = entity.completedAt {
                    timestampLabel("Done", value: formatTimestamp(completed))
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
        let color = statusColor(for: status)
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
    private func priorityBadge(_ priority: String) -> some View {
        let color = priorityColor(for: priority)
        Text(priority)
            .font(TronTypography.mono(size: 11, weight: .medium))
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
    private func progressBadge(completed: Int, total: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(completed)/\(total)")
                .font(TronTypography.mono(size: 11, weight: .semibold))
            Text("tasks")
                .font(TronTypography.mono(size: 11, weight: .regular))
        }
        .foregroundStyle(accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(accentColor.opacity(0.2)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private func countBadge(count: Int, label: String, detail: String? = nil) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(TronTypography.mono(size: 11, weight: .semibold))
            Text(count == 1 ? label : label + "s")
                .font(TronTypography.mono(size: 11, weight: .regular))
            if let detail {
                Text("(\(detail))")
                    .font(TronTypography.mono(size: 10, weight: .regular))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .foregroundStyle(accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(accentColor.opacity(0.2)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private func statusDot(for mark: String) -> some View {
        let color: Color = switch mark {
        case "x": .tronSuccess
        case ">": .tronTeal
        case "b": .tronSlate
        case "-": .tronError
        default: .tronSlate.opacity(0.5)
        }

        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .padding(.top, 5)
    }

    // MARK: - Color Helpers

    private func statusColor(for status: String) -> Color {
        switch status {
        case "completed": return .tronSuccess
        case "in_progress": return .tronTeal
        case "cancelled": return .tronError
        case "backlog": return .tronSlate
        case "paused": return .tronAmber
        case "archived": return .tronSlate
        case "active": return .tronTeal
        default: return .tronSlate
        }
    }

    private func priorityColor(for priority: String) -> Color {
        switch priority {
        case "critical", "[critical]": return .tronError
        case "high", "[high]": return .orange
        case "low", "[low]": return .tronTextMuted
        default: return .tronTextSecondary
        }
    }

    private func formatTimestamp(_ iso: String) -> String {
        // Extract date portion: "2026-02-11T10:00:00Z" → "Feb 11"
        let parts = iso.split(separator: "T")
        guard let datePart = parts.first else { return iso }
        let datePieces = datePart.split(separator: "-")
        guard datePieces.count >= 3,
              let month = Int(datePieces[1]),
              let day = Int(datePieces[2]) else { return String(datePart) }

        let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let monthName = month > 0 && month <= 12 ? monthNames[month] : "\(month)"
        return "\(monthName) \(day)"
    }
}
