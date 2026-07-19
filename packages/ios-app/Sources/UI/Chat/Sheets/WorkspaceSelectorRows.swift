import SwiftUI

struct WorkspaceQuickPath: Identifiable, Equatable {
    let path: String
    let title: String
    let subtitle: String
    let icon: String

    var id: String { path }
}

struct WorkspaceQuickPathPill: View {
    let row: WorkspaceQuickPath
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        WorkspaceCompactPillButton(
            icon: row.icon,
            title: row.title,
            titleColor: .tronTextPrimary,
            tintOpacity: isSelected ? 0.2 : 0.08,
            accessibilityLabel: "\(row.title), \(row.subtitle)",
            action: action
        ) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
            }
        }
    }
}

struct WorkspaceDirectoryActionPill: View {
    let icon: String
    let title: String
    let subtitle: String?
    let action: () -> Void

    var body: some View {
        WorkspaceCompactPillButton(
            icon: icon,
            title: title,
            titleColor: .tronEmerald,
            tintOpacity: 0.09,
            accessibilityLabel: subtitle.map { "\(title), \($0)" } ?? title,
            action: action
        )
    }
}

private struct WorkspaceCompactPillButton<Accessory: View>: View {
    let icon: String
    let title: String
    let titleColor: Color
    let tintOpacity: Double
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    init(
        icon: String,
        title: String,
        titleColor: Color,
        tintOpacity: Double,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.titleColor = titleColor
        self.tintOpacity = tintOpacity
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.accessory = accessory
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 14)

                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)

                accessory()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(tintOpacity)).interactive(),
            in: Capsule()
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension WorkspaceCompactPillButton where Accessory == EmptyView {
    init(
        icon: String,
        title: String,
        titleColor: Color,
        tintOpacity: Double,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.init(
            icon: icon,
            title: title,
            titleColor: titleColor,
            tintOpacity: tintOpacity,
            accessibilityLabel: accessibilityLabel,
            action: action,
            accessory: EmptyView.init
        )
    }
}

struct WorkspaceDirectoryEntryRow: View {
    let entry: WorkspaceDirectoryEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: entry.isSymlink ? "folder.badge.questionmark" : "folder.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)

                Text(entry.name)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronOverlay(0.07)).interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}
